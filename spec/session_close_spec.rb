# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/session_close'
require 'securerandom'

# Something closes a session. #410, the first half.
#
# Sessions stayed open until somebody said otherwise, and the log shows what that cost:
# workout 28 reported 24h 46m, because the first set was marked late one evening and the rest
# the next morning. Several sessions sit at `performed` with a handful of sets done and no
# ending at all, so nothing can tell "stopped here" from "still going".
module SessionClosing
  # A session whose last set was `ago` seconds back. `open` is what makes it interesting: a
  # session nobody has closed is the only kind there is anything to do about.
  def a_session(account_id, ago: 60, sets: 2, rest: 180, finished: nil)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today, finished_at: finished)
    sets.times do |index|
      DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5, is_warmup: false,
                       is_completed: true, is_barbell: true, planned_rest_seconds: rest,
                       completed_at: Time.now - ago - ((sets - 1 - index) * 0))
    end
    workout_id
  end

  # A session written but never started, which has no ending to reach for.
  def a_planned_session(account_id)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                     is_warmup: false, is_completed: false, is_barbell: true)
    workout_id
  end

  def rows_of(workout_id)
    Tectonic::WorkoutSet.where(workout_id:).all.map(&:values)
  end

  def finished_at(workout_id) = Tectonic::Workout[workout_id].finished_at

  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

describe 'how long to leave a session before asking' do
  include SessionClosing

  # At an ordinary three-minute rest the multiple comes to nine minutes, which the floor
  # raises. For most sessions this is the fixed number #410 calls reasonable.
  it 'is the floor where three rests would be shorter than it' do
    account_id = an_account

    assert_equal Tectonic::SessionClose::QUIET_FLOOR,
                 Tectonic::SessionClose.quiet_after(rows_of(a_session(account_id, rest: 180)))
  end

  # Where the multiple earns its place: a block writing eight minutes between heavy singles
  # gets the full half hour, rather than being interrupted while the lifter is still resting.
  it 'is the ceiling where three rests would be longer' do
    account_id = an_account

    assert_equal Tectonic::SessionClose::QUIET_CEILING,
                 Tectonic::SessionClose.quiet_after(rows_of(a_session(account_id, rest: 600)))
  end

  it 'is the ceiling where the block prescribed nothing' do
    account_id = an_account

    assert_equal Tectonic::SessionClose::QUIET_CEILING,
                 Tectonic::SessionClose.quiet_after(rows_of(a_session(account_id, rest: nil)))
  end
end

describe 'sweeping up a session nobody came back to' do
  include SessionClosing

  # The whole of it: the stamp is the last set, not the moment of sweeping. Stamping now would
  # reproduce the reading this issue exists to fix.
  it 'closes it at its own last set rather than at now' do
    account_id = an_account
    workout_id = a_session(account_id, ago: 8 * 60 * 60)
    last = Tectonic::WorkoutSet.where(workout_id:).max(:completed_at)

    Tectonic::SessionClose.sweep(account_id)

    assert_in_delta last.to_f, finished_at(workout_id).to_f, 1
  end

  # Six hours is not a guess about how long a session lasts; it is a length of time after
  # which no reading of the rows has the lifter still in the gym.
  it 'leaves a session that was moving an hour ago alone' do
    account_id = an_account
    workout_id = a_session(account_id, ago: 60 * 60)

    Tectonic::SessionClose.sweep(account_id)

    assert_nil finished_at(workout_id)
  end

  # A session with no completed set has no ending to reach for, and inventing one would close
  # a session that never opened -- which is every planned session sitting in next week.
  it 'leaves a session nobody has started alone' do
    account_id = an_account
    workout_id = a_planned_session(account_id)

    Tectonic::SessionClose.sweep(account_id)

    assert_nil finished_at(workout_id)
  end
end

describe 'sweeping past a session that is not its business' do
  include SessionClosing

  # A session somebody already closed is a statement they made, and re-stamping it would
  # overwrite the answer with a guess.
  it 'leaves a session somebody already closed alone' do
    account_id = an_account
    said = Time.now - (9 * 60 * 60)
    workout_id = a_session(account_id, ago: 10 * 60 * 60, finished: said)

    Tectonic::SessionClose.sweep(account_id)

    assert_in_delta said.to_f, finished_at(workout_id).to_f, 1
  end

  it "never touches another account's sessions" do
    mine = an_account
    theirs = an_account
    workout_id = a_session(theirs, ago: 8 * 60 * 60)

    Tectonic::SessionClose.sweep(mine)

    assert_nil finished_at(workout_id)
  end
end

# Lazily, on the way in and on the calendar, which is where ProgramSchedule already runs and
# for the same reasons: there is no scheduler in this app, and a session nobody looks at is a
# session whose untidy ending nobody reads.
describe 'the pages that tidy a session up' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionClosing

  # Sharper on this page than anywhere else: a session left open two weeks ago is a cell on
  # this very grid, and it would be drawn as a day of training.
  it 'closes an abandoned session when the calendar is opened' do
    account_id = login
    workout_id = a_session(account_id, ago: 8 * 60 * 60)

    get '/'

    refute_nil finished_at(workout_id)
  end

  it 'closes one on the way in from a sign-in' do
    account_id = login
    workout_id = a_session(account_id, ago: 8 * 60 * 60)
    Tectonic.new({}).login_destination(account_id)

    refute_nil finished_at(workout_id)
  end
end

# The two statements are different and the route has to tell them apart. Tapping finish is a
# lifter standing in the gym saying they are done; answering a prompt an hour later is not.
describe 'answering the nudge' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionClosing

  it 'stamps the last completed set rather than the moment of answering' do
    account_id = login
    workout_id = a_session(account_id, ago: 45 * 60)
    last = Tectonic::WorkoutSet.where(workout_id:).max(:completed_at)
    path = "/workouts/#{workout_id}/session/finish"

    post path, { at: 'last', '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) }

    assert_in_delta last.to_f, finished_at(workout_id).to_f, 1
  end

  # A session opened, nothing done in it, and closed. There is no last set to reach for and
  # the moment of closing is the only honest answer left.
  it 'falls back to now where nothing was lifted' do
    account_id = login
    workout_id = a_planned_session(account_id)
    path = "/workouts/#{workout_id}/session/finish"

    post path, { at: 'last', '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) }

    assert_in_delta Time.now.to_f, finished_at(workout_id).to_f, 5
  end
end

describe 'the finish control at the top of the screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionClosing

  # Unchanged by #410, and deliberately: the ten minutes spent putting plates away is time
  # the session cost.
  it 'still stamps the moment it was tapped' do
    account_id = login
    workout_id = a_session(account_id, ago: 45 * 60)
    path = "/workouts/#{workout_id}/session/finish"

    post path, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) }

    assert_in_delta Time.now.to_f, finished_at(workout_id).to_f, 5
  end
end

describe 'the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionClosing

  # Filled in on first paint, which is where this differs from the rest cue beside it. A
  # session opened an hour after its last set should not greet you with a rest timer -- but it
  # absolutely should be asked whether it is finished, because that is the session #410 is
  # about.
  it 'tells the nudge when the session last moved' do
    account_id = login
    workout_id = a_session(account_id, ago: 45 * 60)

    get "/workouts/#{workout_id}/session"

    assert_match(/id="quiet-cue"[^>]*data-last-at="\d+/, last_response.body)
  end

  it 'tells it how long to wait before asking' do
    account_id = login
    workout_id = a_session(account_id, ago: 60, rest: 600)

    get "/workouts/#{workout_id}/session"

    assert_includes last_response.body, %(data-quiet-after="#{Tectonic::SessionClose::QUIET_CEILING}")
  end

  # A session with nothing lifted has no quiet to measure, and the script draws nothing.
  it 'says nothing about quiet on a session nobody has started' do
    account_id = login
    workout_id = a_planned_session(account_id)

    get "/workouts/#{workout_id}/session"

    assert_match(/id="quiet-cue"[^>]*data-last-at=""/, last_response.body)
  end
end

# The nudge is about the session rather than about the tap, so it is sent on every tap --
# including an un-complete, which the rest cue deliberately stays silent about. Taking a
# mis-tap back is still the session moving, and the quiet has to restart from it.
describe 'the cue after a tap' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionClosing

  it 'comes back out of band so the quiet restarts' do
    account_id = login
    workout_id = a_session(account_id, ago: 45 * 60)
    set_id = DB[:sets].where(workout_id:).order(:id).get(:id)
    path = "/workouts/#{workout_id}/sets/#{set_id}/complete"

    post path, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) },
         { 'HTTP_HX_REQUEST' => 'true' }

    assert_match(/id="quiet-cue" hx-swap-oob="true"/, last_response.body)
  end
end

