# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require

# What a tap sends back. #235.
#
# Every form on the session screen posted to /complete and swapped the whole of
# #session-body -- every panel, every row, every form on the page. Measured on a five-lift
# session of twenty-five sets, an ordinary session, that was 129,911 bytes against a page of
# 135,677: 96% of the document, to tint one row and fill one slice of the bar. At roughly
# forty-five taps in a session it came to about 5.7MB, on gym wifi.
#
# It is one lift panel now, with the progress header beside it out of band. Two fragments
# because a tap changes exactly two things and they are not adjacent -- the row is inside a
# panel, the bar is in the sticky header above the scroller.
#
# Both halves are asserted, and the second matters more than the first: a response carrying
# only the panel would be smaller still and would leave the bar disagreeing with the rows
# underneath it, which is worse than sending too much.
module SwapPayload
  def app = Tectonic.app

  # Five lifts of two warmups and three working sets. Sized to be worth measuring rather
  # than to be quick: the cost of the old swap grew with the session, so a one-lift session
  # would have shown almost nothing.
  def a_full_session(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    5.times do |lift|
      exercise_id = DB[:exercises].insert(name: "Lift #{lift} #{SecureRandom.hex(4)}", account_id:)
      common = { workout_id:, exercise_id:, reps: 5, is_barbell: true, is_completed: false }
      2.times { DB[:sets].insert(**common, weight: 95, is_warmup: true) }
      3.times { DB[:sets].insert(**common, weight: 155, is_warmup: false) }
    end
    workout_id
  end

  def tap_done(workout_id, set_id)
    action = "/workouts/#{workout_id}/sets/#{set_id}/complete"
    post action, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", action) },
         { 'HTTP_HX_REQUEST' => 'true' }
    last_response.body
  end
end

describe 'what one tap of Done sends back' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwapPayload

  before do
    @account_id = login
    @workout_id = a_full_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @page = last_response.body.bytesize
    @swap = tap_done(@workout_id, DB[:sets].where(workout_id: @workout_id).order(:id).get(:id))
  end

  # A fraction rather than a byte count, because the page grows with the session and a fixed
  # number would either go stale or be measuring the wrong thing. A third is generous: it is
  # about a fifth today, and this is a guard against the whole body coming back rather than
  # a budget to tune against.
  it 'is a fraction of the page rather than nearly all of it' do
    share = 100.0 * @swap.bytesize / @page

    assert_operator share, :<, 33,
                    "a tap sends back #{share.round}% of the page; it used to send 96% and " \
                    'the whole point of #235 was that it should not'
  end

  # The half that is easy to lose. A response carrying only the panel would be smaller and
  # would leave the bar saying something the rows below it contradict.
  it 'carries the progress header as well as the panel, so the two cannot disagree' do
    assert_includes @swap, 'id="lift-panel-', 'the panel the tap was on should come back'
    assert_includes @swap, 'hx-swap-oob="true"', 'and the header out of band beside it'
    assert_includes @swap, 'id="session-progress"'
  end
end

# That the two fragments are current and are the right two, as against merely present.
describe 'what the two fragments contain' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwapPayload

  before do
    @account_id = login
    @workout_id = a_full_session(@account_id)
    @swap = tap_done(@workout_id, DB[:sets].where(workout_id: @workout_id).order(:id).get(:id))
  end

  # One lift, not five. The other four did not change.
  it 'sends the one panel the tap was on' do
    assert_equal 1, @swap.scan('id="lift-panel-').length
  end

  # The bar is rendered from what is completed, so this is what says the oob fragment is
  # current rather than a copy of what was already on screen before the tap.
  it 'sends a header that already counts the set just completed' do
    assert_includes @swap, '1 of 25 sets'
  end
end

