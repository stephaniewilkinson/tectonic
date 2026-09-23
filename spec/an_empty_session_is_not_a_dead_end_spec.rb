# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'
require 'date'

# Tectonic::Exercise.load_library is what the new-set form's picker is built out of, and the
# last describe in this file posts that form. Seeded here for the reason route_ownership_spec
# gives at its own call: run as part of the whole suite another file has already left library
# rows lying about, and run on its own -- which is how the README says to run one file -- there
# would be none, the post would be refused for a movement that does not resolve, and the
# assertion after it would fail on a suite that is otherwise green.
Tectonic::Exercise.load_library

# A session with nothing in it, opened on the gym floor. #578.
#
# The screenshot on that issue is /workouts/66/session reading "0 of 0 sets" with "finish
# workout" and "Add a note" as the only two controls on the screen. Until now
# views/workouts/session.erb contained no link to /sets/new anywhere: that affordance lived on
# the record page and the set list, both of them a page away, and the gym floor screen was
# built on the assumption that a session already has sets in it.
#
# **How a lifter gets there without doing anything unusual.** The generator schedules a
# session for every day the programme describes, including a day with no lifts written on it,
# and `login_destination` sends a lifter to /workouts/:id/session whenever there is an
# unfinished session dated today. So signing in on such a day landed directly on a screen with
# nothing to do and no way to start doing anything.
#
# Why the session is empty is not what these specs pin. A programme day with nothing on it, a
# session made by hand, a lift deleted down to nothing -- the requirement is the same in every
# case, and it is the one this file is named after.
module EmptySession
  def a_session(account_id) = Tectonic::Workout.create(account_id:, date: Date.today)

  # The same session with one lift on it, which is what the control has to go on being offered
  # on: #578's judgement is that this is not an empty-session feature.
  def a_session_with_a_lift(account_id)
    workout = a_session(account_id)
    exercise = Tectonic::Exercise.create(account_id:, name: "Back Squat #{SecureRandom.hex(4)}",
                                         is_barbell: true)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 155,
                                reps: 5, is_warmup: false, is_barbell: true, is_completed: false)
    [workout, exercise]
  end

  def way_in(workout) = "/workouts/#{workout.id}/sets/new"

  # The new-set form posted the way the form posts it, with whatever the caller wants to say
  # about where it came from merged over the top.
  def write_a_set(extra = {})
    post way_in(@workout),
         { 'exercise_id' => @exercise.id.to_s, 'weight' => '135', 'reps' => '5',
           '_csrf' => token_for(way_in(@workout)) }.merge(extra)
  end

  def landed_on = last_response.headers['Location']
end

describe 'a session with nothing written for it' do
  include Rack::Test::Methods
  include RouteOwnership
  include EmptySession

  before do
    @account_id = login
    @workout = a_session(@account_id)
  end

  it 'offers a way to put a lift on it' do
    get "/workouts/#{@workout.id}/session"

    assert_includes last_response.body, way_in(@workout)
    assert_includes last_response.body, 'Add a lift'
  end

  # A bare "0 of 0 sets" is a true statement that reads as a failure to load. The lifter in
  # #578 had no way to tell a screen with nothing written on it from a screen that had not
  # finished drawing.
  it 'says there is nothing written rather than only counting to zero' do
    get "/workouts/#{@workout.id}/session"

    assert_includes last_response.body, 'Nothing is written for this session'
  end

  it 'says it only while that is true' do
    a_session_with_a_lift(@account_id) => [workout, _]

    get "/workouts/#{workout.id}/session"

    refute_includes last_response.body, 'Nothing is written for this session'
  end
end

# Always offered, not only where the session is empty. A control that appeared on an empty
# session and vanished the moment it had been used once would be gone at exactly the moment a
# lifter wanted it a second time.
describe 'reaching a new lift from a session that already has lifts' do
  include Rack::Test::Methods
  include RouteOwnership
  include EmptySession

  before do
    @account_id = login
    @workout, @exercise = a_session_with_a_lift(@account_id)
  end

  it 'is offered there too' do
    get "/workouts/#{@workout.id}/session"

    assert_includes last_response.body, way_in(@workout)
    assert_includes last_response.body, 'Add a lift'
  end

  # The placement, asserted from the outside. Everything inside #session-body is replaced on
  # every Done tap and on every fifteen-second poll, so a control rendered in there would be
  # sent again by both -- and this one must be rendered exactly once, by the page.
  #
  # Asserting on what the swap responses do *not* carry is the only way a spec can see that
  # from here: a response that contained the link would be one that puts a second copy of it
  # on the screen, or moves the one that is there.
  it 'is not in what a Done tap sends back' do
    action = "/workouts/#{@workout.id}/sets/#{@workout.sets_dataset.first.id}/complete"
    post action, { '_csrf' => token_for_form("/workouts/#{@workout.id}/session", action) },
         { 'HTTP_HX_REQUEST' => 'true' }

    refute_includes last_response.body, way_in(@workout)
  end

  it 'is not in what the poll sends back' do
    get "/workouts/#{@workout.id}/session/changes", { 'since' => 'a digest from before' }

    assert_equal 200, last_response.status
    refute_includes last_response.body, way_in(@workout)
  end
end

# The other half of not being a dead end: the way back. Reached from the gym floor screen, the
# new-set form used to land on the set it had just written -- a page whose only way onwards is
# the record, which is two taps from the session the lifter is standing in the middle of.
describe 'saving a set that was started from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include EmptySession

  before do
    @account_id = login
    @workout = a_session(@account_id)
    @exercise = Tectonic::Exercise.create(account_id: @account_id,
                                          name: "Front Squat #{SecureRandom.hex(4)}")
  end

  it 'comes back to the session' do
    write_a_set('return_to' => 'session')

    assert_equal "/workouts/#{@workout.id}/session", landed_on
  end

  # The form bounces back to itself when the movement or the rep count will not do. It has to
  # bounce back to the form *as it was opened*, or a mistyped rep count costs the lifter the
  # way home as well as the set.
  it 'keeps the way back when the form refuses what was typed' do
    write_a_set('return_to' => 'session', 'reps' => '')

    assert_equal "/workouts/#{@workout.id}/sets/new?return_to=session", landed_on
  end
end

describe 'saving a set that was started anywhere else' do
  include Rack::Test::Methods
  include RouteOwnership
  include EmptySession

  before do
    @account_id = login
    @workout = a_session(@account_id)
    @exercise = Tectonic::Exercise.create(account_id: @account_id,
                                          name: "Front Squat #{SecureRandom.hex(4)}")
  end

  # The record page and the set list are unchanged by #578. The set they write is still
  # confirmed by landing on it, which is the right answer for a form opened one tap away from
  # the record and the wrong one for a lifter standing mid-session.
  it 'still lands on the set' do
    write_a_set

    assert_match %r{/workouts/#{@workout.id}/sets/\d+/}, landed_on
  end

  # return_to is a fixed token rather than a path, so nothing a request says can decide where
  # a redirect goes. Anything that is not the word the session screen sends is ignored.
  it 'will not be talked into going somewhere else' do
    write_a_set('return_to' => 'https://example.com/')

    assert_match %r{/workouts/#{@workout.id}/sets/\d+/}, landed_on
  end
end

