# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require

# The half of the scale the session screen could not say. #442.
#
# Reported as "RPE can't always be entered" -- recordable on some sets and not on others, the
# same account in the same week. It was not intermittent and it was not about completion: the
# buttons ran 6 to 10, and the sets that could not be rated were the ones prescribed below 6.
#
# Migration 019 opened the gap on purpose and wrote down that it was doing so. It bounded
# planned_rpe at 1 to 10 rather than 6 to 10 because *"speed work and deload weeks are written
# at 5 and 6, and a column refusing a 5 would make a real prescription unwritable while
# sets.rpe cheerfully stored the answer to it."* The generator then wrote those weeks, and the
# screen had nothing to answer them with. `Bounds::RPE` on the MCP side is already (1..10), so
# the rating could be recorded over the API and not by the lifter holding the phone.
#
# The cost is the autoregulation loop (#449) going quiet on exactly the weeks it was told to
# back off: on the reporting account 1 of the 30 working sets prescribed at RPE 4 to 6 carries
# a rating, against 14 of the 36 prescribed at 7 and 8.
module DeloadRating
  # A session with one working set, optionally carrying a prescribed effort.
  def a_set_asking_for(account_id, planned_rpe)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Bench #{SecureRandom.hex(4)}", account_id:)
    set_id = DB[:sets].insert(workout_id:, exercise_id:, weight: 95, reps: 5, planned_rpe:,
                              is_warmup: false, is_completed: false, is_barbell: true)
    [workout_id, set_id]
  end

  # The ratings actually on offer for a set, read off the page.
  #
  # Scoped to the form carrying rating buttons rather than to the whole body, because every
  # form on a set posts to the same complete path -- Done, the revision box and the ratings --
  # and the revision box carries a weight field whose numbers would otherwise be counted as
  # though they were ratings.
  def ratings_offered(set_id)
    form = last_response.body
                        .scan(%r{<form[^>]*action="[^"]*/sets/#{set_id}/complete"[^>]*>.*?</form>}m)
                        .find { |f| f.include?('name="rpe"') }
    return [] unless form

    form.scan(/<button value="(\d+)"[^>]*name="rpe"/m).flatten.map(&:to_i).sort
  end

  def rating_buttons_for(account_id, planned_rpe)
    workout_id, set_id = a_set_asking_for(account_id, planned_rpe)
    get "/workouts/#{workout_id}/session"
    ratings_offered(set_id)
  end
end

describe 'the ratings a set is offered' do
  include Rack::Test::Methods
  include RouteOwnership
  include DeloadRating

  before { @account_id = login }

  # The reported set, exactly: three completed bench sets at planned_rpe 5 with rpe null.
  it 'includes the one it was prescribed at, on a deload' do
    assert_includes rating_buttons_for(@account_id, 5), 5
  end

  # Speed work, which 019 names alongside deloads as the other thing written down here.
  it 'reaches a prescription written lower still' do
    assert_includes rating_buttons_for(@account_id, 4), 4
  end

  # The property a window centred on the target would have cost, and the reason the row runs
  # to the top rather than merely covering the prescription. A deload set that turns out to be
  # an RPE 9 is the single most useful thing a lifter can report about a deload, and it is the
  # reading the next block should be written against.
  it 'still reaches the top of the scale on a light prescription' do
    assert_includes rating_buttons_for(@account_id, 4), 10
  end

  # Five buttons was a decision about a thumb on a phone with chalk on, not an oversight, so
  # the ordinary case has to come back unchanged rather than merely still working.
  it 'is exactly the five it always was where the prescription is a heavy one' do
    assert_equal [6, 7, 8, 9, 10], rating_buttons_for(@account_id, 8)
  end

  it 'is the same five where nothing was prescribed at all' do
    assert_equal [6, 7, 8, 9, 10], rating_buttons_for(@account_id, nil)
  end

  it 'does not widen for a prescription already inside the row' do
    assert_equal [6, 7, 8, 9, 10], rating_buttons_for(@account_id, 6)
  end
end

# Widening a flex row of flex-1 children shrinks them, which would have answered "I cannot
# record this rating" with "every rating is now harder to hit" -- and the row is tapped 45
# times in a session, one-handed. min-w-11 is 44px, so the buttons wrap onto a second line
# instead of narrowing.
describe 'what widening the row must not cost' do
  include Rack::Test::Methods
  include RouteOwnership
  include DeloadRating

  before do
    @account_id = login
    workout_id, @set_id = a_set_asking_for(@account_id, 4)
    get "/workouts/#{workout_id}/session"
  end

  it 'keeps every rating button at the minimum touch size' do
    buttons = last_response.body.scan(/<button value="\d+"[^>]*name="rpe"[^>]*>/m)
    refute_empty buttons
    buttons.each do |button|
      assert_includes button, 'min-w-11'
      assert_includes button, 'min-h-12'
    end
  end

  it 'lets the row wrap rather than squeeze' do
    form = last_response.body[%r{<form[^>]*/sets/#{@set_id}/complete"[^>]*class="[^"]*flex-wrap[^"]*"}m]
    refute_nil form
  end
end

# The other half of the report -- "editable after the fact" -- which turned out to be working
# already. Asserted rather than assumed, because nothing else pinned it and the fix above
# would have hidden a second bug behind a first.
describe 'rating a set that is already done' do
  include Rack::Test::Methods
  include RouteOwnership
  include DeloadRating

  # Through the form's own token rather than the page's, which is the trap token_for_form
  # exists for: every form on this screen posts to the complete path, so a token taken from
  # the page would be refused 403 and the spec would pass on a request that never happened.
  def rate(workout_id, set_id, rpe)
    action = "/workouts/#{workout_id}/sets/#{set_id}/complete"
    post action, { 'rpe' => rpe.to_s,
                   '_csrf' => token_for_form("/workouts/#{workout_id}/session", action) }
  end

  it 'records the rating and leaves it done' do
    account_id = login
    workout_id, set_id = a_set_asking_for(account_id, 5)
    DB[:sets].where(id: set_id).update(is_completed: true, completed_at: Time.now)

    rate(workout_id, set_id, 5)

    row = DB[:sets][id: set_id]
    assert_equal 5, row[:rpe]
    assert row[:is_completed], 'rating a finished set must not un-finish it'
  end

  it 'corrects a rating already given without un-completing the set' do
    account_id = login
    workout_id, set_id = a_set_asking_for(account_id, 5)
    DB[:sets].where(id: set_id).update(is_completed: true, completed_at: Time.now, rpe: 9)

    rate(workout_id, set_id, 5)

    assert_equal 5, DB[:sets][id: set_id][:rpe]
    assert DB[:sets][id: set_id][:is_completed]
  end
end

