# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/timing'
require 'securerandom'
require 'date'

# A rest you can set, so the bell can ring. #456.
#
# The session screen has been able to count a rest down and ring since #281 and #395, and it
# has never done it for anybody. It rings on a *prescribed* rest -- `planned_rest_seconds` on
# the set, copied from `program_lifts.rest_seconds` at generation -- and no lift had ever
# carried one: 126 program lifts on the reporting account, not a single rest.
#
# Unreachable by design rather than by oversight. `add_program_lift` tells assistants to
# "leave it out rather than inventing a number", and #411 removed the block editor, so the only
# way to ask for a bell was to ask an assistant, lift by lift.
#
# **What earns the bell is that somebody named the length.** The timer's own rule. A countdown
# that rings unasked is the app interrupting a session, and #263 settled that the app does not
# decide how long anybody rests -- so a constant picked in the code could not ring, and a
# number the lifter typed on the movement's page can.
module RingingRest
  def a_movement(account_id, rest: nil)
    Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}",
                              is_barbell: true, default_rest_seconds: rest)
  end

  # A session with one working set, *not* ticked off -- because the thing under test is the
  # tap that ticks it.
  def a_session(account_id, exercise, planned_rest: nil)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    set = Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 155,
                                      reps: 5, is_warmup: false, planned_rest_seconds: planned_rest,
                                      is_completed: false)
    [workout, set]
  end

  # What the server tells the timer when a set is saved, which is the only moment it says
  # anything. The cue means "a set was just finished", so on first paint it is deliberately
  # empty -- reading it there would be testing the wrong surface, and an assertion that passed
  # on a page load would not be about the bell at all.
  def cue_on_saving(account_id, exercise, planned_rest: nil)
    workout, set = a_session(account_id, exercise, planned_rest:)
    action = "/workouts/#{workout.id}/sets/#{set.id}/complete"
    post action, { '_csrf' => token_for_form("/workouts/#{workout.id}/session", action) },
         { 'HTTP_HX_REQUEST' => 'true' }
    span = last_response.body[/<span id="rest-cue"[^>]*>/]
    { seconds: span[/data-suggested="([^"]*)"/, 1], kind: span[/data-kind="([^"]*)"/, 1] }
  end
end

describe 'a rest set on the movement' do
  include Rack::Test::Methods
  include RouteOwnership
  include RingingRest

  before { @account_id = login }

  # The whole point. `prescribed` is the kind the timer counts down and rings on without a
  # second tap; `usual` is offered on the bar and waits to be asked.
  it 'reaches the timer as a rest that rings' do
    assert_equal({ seconds: '180', kind: 'prescribed' },
                 cue_on_saving(@account_id, a_movement(@account_id, rest: 180)))
  end

  # A block is more specific than a movement: a week of heavy singles may want five minutes on
  # a squat usually rested three.
  it 'gives way to the rest the block prescribed for this set' do
    cue = cue_on_saving(@account_id, a_movement(@account_id, rest: 180), planned_rest: 300)

    assert_equal '300', cue[:seconds]
  end

  # Unchanged for everybody who sets nothing, which is the ordinary case: the timer goes on
  # offering the lifter's own median, which takes a tap and never rings unasked.
  it 'leaves a movement with no rest exactly as it was' do
    cue = cue_on_saving(@account_id, a_movement(@account_id))

    refute_equal 'prescribed', cue[:kind]
  end
end

describe 'setting a rest on the movement page' do
  include Rack::Test::Methods
  include RouteOwnership
  include RingingRest

  before do
    @account_id = login
    @exercise = a_movement(@account_id)
  end

  def save(seconds)
    post '/exercises', { 'id' => @exercise.id.to_s, 'name' => @exercise.name,
                         'default_rest_seconds' => seconds,
                         '_csrf' => token_for("/exercises/#{@exercise.id}/edit") }
  end

  it 'offers the field' do
    get "/exercises/#{@exercise.id}/edit"

    assert_includes last_response.body, 'name="default_rest_seconds"'
  end

  it 'records it' do
    save('180')

    assert_equal 180, @exercise.refresh.default_rest_seconds
  end

  # Blank is the ordinary answer and has to stay sayable: it is how a bell is turned off.
  it 'takes a blank as no bell' do
    save('180')
    save('')

    assert_nil @exercise.refresh.default_rest_seconds
  end
end

# The check constraint would refuse these and surface as a 500 on a Save button. Refused
# rather than clamped: clamping 9000 to 1800 would store a number nobody typed and then ring
# at them for half an hour of it.
describe 'a rest nobody takes' do
  include Rack::Test::Methods
  include RouteOwnership
  include RingingRest

  before do
    @account_id = login
    @exercise = a_movement(@account_id)
  end

  def save(seconds)
    post '/exercises', { 'id' => @exercise.id.to_s, 'name' => @exercise.name,
                         'default_rest_seconds' => seconds,
                         '_csrf' => token_for("/exercises/#{@exercise.id}/edit") }
  end

  it 'is refused rather than clamped when it is too long' do
    save('9000')

    assert_nil @exercise.refresh.default_rest_seconds
  end

  it 'is refused when it is too short to be a rest' do
    save('2')

    assert_nil @exercise.refresh.default_rest_seconds
  end
end

# Said back in the units a person thinks in, through the same phrasing the session screen and
# the turnaround readings already use.
describe 'what the movement page says back' do
  include Rack::Test::Methods
  include RouteOwnership
  include RingingRest

  it 'reads the seconds back as a duration' do
    account_id = login
    exercise = a_movement(account_id, rest: 180)

    get "/exercises/#{exercise.id}/edit"

    assert_includes last_response.body.gsub(/\s+/, ' '), Tectonic::Timing.phrase(180)
  end
end

