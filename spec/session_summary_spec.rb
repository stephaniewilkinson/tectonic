# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/session_summary'
require 'securerandom'

# What went well, named specifically. #410, the second half.
#
# The requirement that shapes every assertion here is the issue's own warning: **"Do not
# manufacture a win that isn't in the data. A summary that praises everything stops being
# read."** So as many of these are about silence as about sentences -- a session with nothing
# to say has to say nothing, or the rest of it stops being worth reading by the third week.
module Summaries
  def a_finished_session(account_id, finished: Time.now, date: Date.today)
    DB[:workouts].insert(account_id:, date:, finished_at: finished)
  end

  def a_movement(account_id, name: 'Bench')
    Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: true)
  end

  def log(workout_id, exercise, **overrides)
    DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 100, reps: 5, rpe: 8,
                       is_warmup: false, is_completed: true, is_barbell: true,
                       completed_at: Time.now, planned_weight: 100, planned_reps: 5,
                       planned_rpe: 8 }.merge(overrides))
  end

  def summarise(workout_id, timing: nil)
    workout = Tectonic::Workout[workout_id]
    sets = Tectonic::WorkoutSet.where(workout_id:).all.map(&:values)
    Tectonic::SessionSummary.of(workout, sets, timing || Tectonic::Timing.session(workout, sets))
  end

  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

describe 'a session where a set went past what was written' do
  include Summaries

  it 'names the set, the numbers and the difference' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), reps: 7, planned_reps: 5)

    assert_match(/7.*planned 100x5 -- 2 extra reps/, summarise(workout_id).first)
  end

  # The part of it worth reading, and only where both numbers exist and the rating is
  # genuinely under the target. Saying it about a set taken at exactly the target would be a
  # small lie in the direction of praise.
  it 'says it was easier than asked for only when it was' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), reps: 7, planned_reps: 5, rpe: 6, planned_rpe: 8)

    assert_includes summarise(workout_id).first, 'at a lower effort than asked for'
  end

  it 'says nothing about effort on a set taken at its target' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), reps: 7, planned_reps: 5, rpe: 8, planned_rpe: 8)

    refute_includes summarise(workout_id).first, 'lower effort'
  end
end

# A session where five sets each went a rep over is one fact about the session, not five, and
# printing it five times is what makes a summary stop being read.
describe 'a session where several sets went past what was written' do
  include Summaries

  it 'names the best one rather than all of them' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    exercise = a_movement(account_id)
    3.times { log(workout_id, exercise, reps: 7, planned_reps: 5) }

    assert_equal(1, summarise(workout_id).count { |line| line.include?('extra rep') })
  end
end

# A set logged heavier than planned is usually the lifter correcting what the bar actually had
# on it rather than beating anything -- #215 is about exactly that edit -- so calling it a win
# would be reading a typo as an achievement.
describe 'a set logged heavier than it was written' do
  include Summaries

  it 'is not called beating the plan' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), weight: 120, planned_weight: 100)

    refute(summarise(workout_id).any? { |line| line.include?('extra rep') })
  end
end

describe 'a session that moved a movement on' do
  include Summaries

  it 'says what it moved to and what from' do
    account_id = an_account
    exercise = a_movement(account_id)
    earlier = a_finished_session(account_id, date: Date.today - 7)
    log(earlier, exercise, weight: 100, reps: 5, rpe: 10, completed_at: Time.now - (7 * 86_400))
    workout_id = a_finished_session(account_id)
    log(workout_id, exercise, weight: 120, reps: 5, rpe: 10)

    assert(summarise(workout_id).any? { |line| line.match?(/puts your .* at \d+, up from \d+/) })
  end

  # A first-ever session of a lift sets every number it touches, and "up from nothing" is not
  # a thing that happened.
  it 'says nothing on a movement with no history behind it' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), weight: 120, reps: 5, rpe: 10)

    refute(summarise(workout_id).any? { |line| line.include?('up from') })
  end

  # The comparison has to be against what was true before this session. Against "the max
  # today" it would include the sets being asked about and could never move.
  it 'says nothing when the session did not beat what came before it' do
    account_id = an_account
    exercise = a_movement(account_id)
    earlier = a_finished_session(account_id, date: Date.today - 7)
    log(earlier, exercise, weight: 200, reps: 5, rpe: 10, completed_at: Time.now - (7 * 86_400))
    workout_id = a_finished_session(account_id)
    log(workout_id, exercise, weight: 100, reps: 5, rpe: 10)

    refute(summarise(workout_id).any? { |line| line.include?('up from') })
  end
end

describe 'getting the whole session done' do
  include Summaries

  it 'says how much, in how long' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    exercise = a_movement(account_id)
    log(workout_id, exercise, completed_at: Time.now - 600)
    log(workout_id, exercise, completed_at: Time.now)

    assert(summarise(workout_id).any? { |line| line.match?(/2 sets in \d+m/) })
  end

  # A short session with half its sets unticked is fast for the obvious reason, and calling
  # that getting the work done would be the manufactured win the issue warns about.
  it 'says nothing about a session that stopped half way' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    exercise = a_movement(account_id)
    log(workout_id, exercise, completed_at: Time.now - 600)
    log(workout_id, exercise, is_completed: false, completed_at: nil)

    refute(summarise(workout_id).any? { |line| line.include?('sets in') })
  end
end

describe 'how often this week' do
  include Summaries

  it 'counts the sessions from the second onwards' do
    account_id = an_account
    monday = Date.today - ((Date.today.wday - 1) % 7)
    exercise = a_movement(account_id)
    first = a_finished_session(account_id, date: monday)
    log(first, exercise, completed_at: Time.now - 86_400)
    workout_id = a_finished_session(account_id, date: Date.today)
    log(workout_id, exercise)

    assert(summarise(workout_id).any? { |line| line.match?(/session this week/) })
  end

  # The first session of a week is not a streak, and calling it one would be praise dressed
  # as a count.
  it 'says nothing about the first session of a week' do
    account_id = an_account
    monday = Date.today - ((Date.today.wday - 1) % 7)
    workout_id = a_finished_session(account_id, date: monday)
    log(workout_id, a_movement(account_id))

    refute(summarise(workout_id).any? { |line| line.include?('session this week') })
  end
end

# The issue's own instruction for the day nothing was beaten: "If nothing beat the plan, say
# what held." Still a comparison rather than praise.
describe 'a session lifted exactly as written' do
  include Summaries

  it 'says what held rather than nothing at all' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id))

    assert_includes summarise(workout_id), 'Every prescribed set completed, none harder than asked for.'
  end

  # An unrated set cannot have been harder than it was asked to be -- there is no comparison
  # to fail -- and treating one as a failure would make this depend on how diligently somebody
  # tapped RPE buttons rather than on how the session went.
  it 'still says it when nobody rated anything' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), rpe: nil)

    assert_includes summarise(workout_id), 'Every prescribed set completed, none harder than asked for.'
  end

  it 'says nothing where a set was harder than it was asked to be' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), rpe: 10, planned_rpe: 7)

    assert_empty summarise(workout_id)
  end
end

# The property the whole thing rests on. A summary that appears every time, saying something
# every time, is a summary nobody reads by the third week.
describe 'a session with nothing to say about it' do
  include Summaries

  it 'says nothing' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    exercise = a_movement(account_id)
    log(workout_id, exercise, rpe: 10, planned_rpe: 7)
    log(workout_id, exercise, is_completed: false, completed_at: nil)

    assert_empty summarise(workout_id)
  end

  it 'says nothing about a session nobody has lifted anything in' do
    account_id = an_account
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), is_completed: false, completed_at: nil)

    assert_empty summarise(workout_id)
  end
end

describe 'the record page' do
  include Rack::Test::Methods
  include RouteOwnership
  include Summaries

  # Only on a finished session, which is what the first half of #410 exists to produce: "on
  # finish, lead with what went well" is a sentence about a moment, and until something closed
  # a session there was no moment to lead with.
  it 'says nothing on a session that is still running' do
    account_id = login
    workout_id = a_finished_session(account_id, finished: nil)
    log(workout_id, a_movement(account_id), reps: 7, planned_reps: 5)

    get "/workouts/#{workout_id}"

    refute_includes last_response.body, 'extra rep'
  end

  it 'leads with it once the session is finished' do
    account_id = login
    workout_id = a_finished_session(account_id)
    log(workout_id, a_movement(account_id), reps: 7, planned_reps: 5)

    get "/workouts/#{workout_id}"

    assert_includes last_response.body, 'extra rep'
  end
end

# #410 asks for this ordering in so many words: "a session that ran long and still moved a
# training max is a good session, and the ordering should say so." The diagnostics are #409's
# and belong below.
describe 'the summary against the diagnostics' do
  include Rack::Test::Methods
  include RouteOwnership
  include Summaries

  it 'puts what went well above what went long' do
    account_id = login
    workout_id = a_finished_session(account_id)
    exercise = a_movement(account_id)
    log(workout_id, exercise, reps: 7, planned_reps: 5, completed_at: Time.now - 900,
                              planned_rest_seconds: 60)
    log(workout_id, exercise, completed_at: Time.now)
    log(workout_id, exercise, is_completed: false, completed_at: nil)

    get "/workouts/#{workout_id}"

    assert_operator last_response.body.index('extra rep'), :<, last_response.body.index('unfinished')
  end
end

