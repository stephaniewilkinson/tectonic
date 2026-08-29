# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #249: the one screen in this app where something genuinely changes underneath a page that
# is already open.
#
# Fifteen MCP tools carry `scope :write` and four of them write to a workout you may be
# looking at right now. Nothing crashes when they do -- every route is account-scoped and
# every write goes through own_set -- but the screen goes on showing what was true when it
# loaded, and the next tap posts against a set that has moved on. A set an assistant
# completed still shows Done, so tapping it toggles it back; a weight it corrected still
# shows the old number, with plate math for a load nobody is being asked to lift.
#
# Answered with polling. #248 settled that websockets are not worth replacing the web
# server for, and the browser has nothing to push here anyway.
module SessionPolling
  def a_session(account_id, weight: 155)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, reps: 5, is_barbell: true }
    DB[:sets].insert(**common, weight: 45, is_warmup: true, is_completed: false)
    @set_id = DB[:sets].insert(**common, weight:, is_warmup: false, is_completed: false)
    workout_id
  end

  # The poll element as rendered, which carries the digest the page was drawn from.
  def poller(body = last_response.body)
    body[/<div id="session-poll"[^>]*>/]
  end

  def fingerprint_in(body = last_response.body)
    poller(body)[/[?&]since=([a-f0-9]+)/, 1]
  end

  def poll(workout_id, since)
    get "/workouts/#{workout_id}/session/changes", since:
  end
end

describe 'the session screen asking whether anything changed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    get "/workouts/#{@workout_id}/session"
  end

  it 'carries a poller with the digest it was drawn from' do
    refute_nil poller, 'the session screen has nothing polling on it'
    assert_match(/\A[a-f0-9]{32}\z/, fingerprint_in)
  end

  # Load-bearing rather than incidental. Swapping #session-body would destroy #lift-panels
  # and take its scrollLeft with it, dropping a lifter back on lift one -- which is the bug
  # #235 removed, and this would put it back on a fifteen-second timer. Replacing the
  # panels *inside* the scroller leaves the scroller itself alone.
  it 'aims at the panels inside the scroller rather than at the scroller' do
    assert_includes poller, 'hx-target="#lift-panels"'
    assert_includes poller, 'hx-swap="innerHTML"'
  end

  # It is the one element on this screen that must survive the swap it asks for, so it
  # has to sit outside the element it replaces.
  it 'sits outside the panels it swaps, so it does not remove itself' do
    body = last_response.body

    assert_operator body.index('id="session-poll"'), :<, body.index('id="lift-panels"')
  end
end

describe 'a poll that finds nothing has changed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @fingerprint = fingerprint_in
  end

  # The whole reason polling is cheap enough to be right here. htmx does not swap on a 204,
  # so the ordinary case -- which is nearly every poll -- touches no DOM at all: no open
  # <details> snapping shut, no swap landing between a thumb and a Done button.
  it 'answers 204 and says nothing' do
    poll(@workout_id, @fingerprint)

    assert_equal 204, last_response.status
    assert_empty last_response.body
  end

  # Reading the session must not change what the session is, or the poll after this one
  # would report news of itself forever.
  it 'answers 204 again, and again' do
    3.times do
      poll(@workout_id, @fingerprint)

      assert_equal 204, last_response.status
    end
  end
end

describe 'a poll that finds a set has moved under it' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @stale = fingerprint_in
  end

  # The middle failure of the three, and the worst: silently wrong rather than visibly
  # broken, because the plate math under it is for a load nobody is being asked to lift.
  # The loads are matched with their unit rather than as bare numbers, and that is not
  # tidiness. `refute_includes body, '155'` matched any occurrence of those three digits
  # anywhere in the markup -- and every set on this screen writes its own id into a form
  # action, a label `for`, and an input id. So the assertion failed whenever the sets
  # sequence happened to hand this fixture id 155, which depends on how many rows the run
  # created before it, which depends on the seed and on what the database was left at by the
  # run before. Green on almost every seed and red on a few, for a reason that has nothing
  # to do with the app.
  #
  # `load_label` renders "185 lb × 5" since #280, so the unit is what tells a weight apart
  # from an id -- no id is ever followed by " lb".
  it 'sends the panels back when an assistant corrects a weight' do
    DB[:sets].where(id: @set_id).update(weight: 185)
    poll(@workout_id, @stale)

    assert_equal 200, last_response.status
    assert_includes last_response.body, '185 lb'
    refute_includes last_response.body, '155 lb'
  end

  it 'sends them back when an assistant completes a set' do
    DB[:sets].where(id: @set_id).update(is_completed: true)
    poll(@workout_id, @stale)

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Undo'
  end
end

# A per-panel swap could not express this: deleting the last set of a lift takes the whole
# panel off the screen, and there is nothing left to swap in its place. Rendering every
# panel is what makes a deletion no harder than an edit.
describe 'a poll that finds a set has been deleted under it' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  it 'sends the panels back without it' do
    account_id = login
    workout_id = a_session(account_id)
    get "/workouts/#{workout_id}/session"
    stale = fingerprint_in
    DB[:sets].where(id: @set_id).delete
    poll(workout_id, stale)

    assert_equal 200, last_response.status
    refute_includes last_response.body, '155'
  end
end

describe 'what a poll sends back beside the panels' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @stale = fingerprint_in
    DB[:sets].where(id: @set_id).update(is_completed: true)
    poll(@workout_id, @stale)
  end

  # The header sits outside the scroller, so it cannot ride along in the main swap.
  it 'brings the progress header, out of band' do
    assert_match(/<div id="session-progress" hx-swap-oob="true"/, last_response.body)
  end
end

# The poller carries the digest it asked about, so a response that changes the session has
# to re-arm it. One still asking about the old digest would find it changed on every poll
# from then on and swap the panels every fifteen seconds forever.
describe 'the poller after something has changed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @stale = fingerprint_in
  end

  it 'comes back out of band with the new digest' do
    DB[:sets].where(id: @set_id).update(weight: 185)
    poll(@workout_id, @stale)

    assert_includes poller, 'hx-swap-oob="true"'
    refute_equal @stale, fingerprint_in
  end

  it 'settles, so the next poll is quiet again' do
    DB[:sets].where(id: @set_id).update(weight: 185)
    poll(@workout_id, @stale)
    poll(@workout_id, fingerprint_in)

    assert_equal 204, last_response.status
  end
end

# A lifter's own tap changes the session too, and the response to it comes from a different
# route. Without re-arming there, the poll fifteen seconds later would find the session
# changed -- by them, a moment ago -- and swap every panel back over the top of it.
describe 'the poller after the lifter taps Done' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  it 'is re-armed by the tap, so the next poll finds nothing' do
    account_id = login
    workout_id = a_session(account_id)
    path = "/workouts/#{workout_id}/sets/#{@set_id}/complete"
    token = token_for_form("/workouts/#{workout_id}/session", path)
    # As the button posts it: the route answers a plain post with a redirect and an htmx
    # one with the swap, and the swap is what carries the re-armed poller.
    post path, { '_csrf' => token }, { 'HTTP_HX_REQUEST' => 'true' }

    assert_equal 200, last_response.status
    poll(workout_id, fingerprint_in)

    assert_equal 204, last_response.status
  end
end

describe 'polling a session that is not yours' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionPolling

  it 'is refused by the same gate as every other workout route' do
    login
    theirs, = strangers_workout
    poll(theirs, 'whatever')

    assert_equal 302, last_response.status
    assert_equal '/workouts', last_response.headers['location']
  end
end

