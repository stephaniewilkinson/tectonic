# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/session_length'
require_relative '../lib/tectonic/turnarounds'
require 'securerandom'

# A session has a length before anybody takes it. #408.
#
# A generated deadlift day came out at 29 sets across four loaded movements -- roughly ninety
# minutes against a one-hour cap -- and nothing flagged it. The lifter found out by running
# out of time.
#
# #263 built the measurement half: a finished session reports how long it ran. What was
# missing is the other direction, and #281 made it cheap by putting planned_rest_seconds on
# every working set, so a day's length is arithmetic on rows that already exist.
module SessionLengths
  # A lifter with no history at all, which is the third branch of rest_for.
  NOTHING_MEASURED = ->(_exercise_id) {}

  # A set as the estimator reads one: plain keys, because it is handed `values` hashes rather
  # than models by both of its callers.
  def set_row(**overrides)
    { exercise_id: 1, reps: 5, measure: 'reps', duration_seconds: nil,
      is_per_side: false, planned_rest_seconds: nil }.merge(overrides)
  end

  def estimate(rows, turnaround: NOTHING_MEASURED)
    Tectonic::SessionLength.estimate(rows, turnaround:)
  end

  # A real session on the table, for the screen that draws the estimate.
  def a_session(account_id, sets: 3, **overrides)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    sets.times do
      DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                         is_warmup: false, is_completed: false, is_barbell: true,
                         planned_rest_seconds: 180 }.merge(overrides))
    end
    workout_id
  end

  # 20 sets of 5 at three minutes' rest is well over an hour, and nothing said so before #408.
  def a_long_block(account_id, budget:)
    exercise = Tectonic::Exercise.create(account_id:, name: "Deadlift #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true,
                                       time_budget_minutes: budget)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 20, reps: 5, top_weight: 315, progression: 'linear',
                                 is_barbell: true, is_main: true, rest_seconds: 180)
    program
  end

  # Two sets ninety seconds apart in one session, which is the smallest thing a median can be
  # taken of.
  def a_measured_movement(account_id, gap: 90)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    [0, gap].each do |offset|
      DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5, is_warmup: false,
                       is_completed: true, is_barbell: true, completed_at: Time.now + offset)
    end
    exercise
  end

  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

describe 'a set the block prescribed a rest for' do
  include SessionLengths

  # The whole of what #281 made possible: no observed data, no model, just the number the
  # block wrote plus a constant for the work.
  it 'is priced at that rest plus its working time' do
    found = estimate([set_row(planned_rest_seconds: 180)])

    assert_equal 180 + 20 + (5 * 4), found.seconds
    assert_equal 1, found.prescribed
  end
end

describe 'a set the block said nothing about' do
  include SessionLengths

  # The same fallback the rest timer uses, and it has to be the same one: a timer counting
  # down 90 seconds under a page that had budgeted 150 for that set would be two numbers from
  # one app disagreeing about one set.
  it 'falls back to what this lifter usually takes' do
    found = estimate([set_row], turnaround: ->(_id) { 90 })

    assert_equal 90 + 20 + (5 * 4), found.seconds
    assert_equal 1, found.measured
  end

  # A movement being trained for the first time has neither. The number is invented, and the
  # count is how a caller finds that out.
  it 'assumes a default, and says that it did' do
    found = estimate([set_row])

    assert_equal Tectonic::SessionLength::DEFAULT_REST_SECONDS + 20 + (5 * 4), found.seconds
    assert_equal 1, found.assumed
    assert found.assumed?
  end

  it 'says nothing was assumed when nothing was' do
    refute estimate([set_row(planned_rest_seconds: 120)]).assumed?
  end
end

# The three counts add up to the sets, so "fifty minutes, all prescribed" and "fifty minutes,
# half assumed" can be told apart -- the same number and very different claims.
describe 'a session priced three different ways' do
  include SessionLengths

  it 'accounts for every set exactly once' do
    rows = [set_row(planned_rest_seconds: 180), set_row(exercise_id: 2), set_row(exercise_id: 3)]
    found = estimate(rows, turnaround: ->(id) { id == 2 ? 90 : nil })

    assert_equal 1, found.prescribed
    assert_equal 1, found.measured
    assert_equal 1, found.assumed
    assert_equal rows.length, found.sets
  end
end

describe 'the working time of one set' do
  include SessionLengths

  # A single and a set of twenty are not the same minute, which is why the constant has a
  # per-rep term rather than being flat.
  it 'grows with the rep count' do
    single = estimate([set_row(reps: 1, planned_rest_seconds: 60)]).seconds
    twenty = estimate([set_row(reps: 20, planned_rest_seconds: 60)]).seconds

    assert_operator twenty, :>, single
  end

  # The one piece of working time here that is a fact rather than a constant: a held position
  # takes as long as the prescription says to hold it.
  it 'is the prescribed duration on a set held for time' do
    found = estimate([set_row(measure: 'time', reps: nil, duration_seconds: 90,
                              planned_rest_seconds: 60)])

    assert_equal 90 + 60, found.seconds
  end

  # Volume has doubled a per-side count since #279, and an estimate that did not would halve
  # the length of a session of unilateral accessories -- exactly the kind that overruns.
  it 'doubles a count that is per side' do
    both = estimate([set_row(reps: 8, is_per_side: true, planned_rest_seconds: 60)]).seconds
    one = estimate([set_row(reps: 8, planned_rest_seconds: 60)]).seconds

    assert_equal 8 * 4, both - one
  end
end

describe 'the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionLengths

  # The number a lifter with a lunch hour is actually after. The elapsed clock beside it says
  # how long they have been here; neither answers "am I going to make it" alone.
  it 'says about how long is left' do
    account_id = login
    workout_id = a_session(account_id)

    get "/workouts/#{workout_id}/session"

    assert_match(/about \d+m left/, last_response.body)
  end

  # "about" is not hedging: a fifth of this is a constant nobody measured. The word is what
  # stops an honest estimate from reading as a promise.
  it 'calls it an estimate rather than stating it' do
    account_id = login
    workout_id = a_session(account_id)

    get "/workouts/#{workout_id}/session"

    assert_includes last_response.body, 'about'
  end

  # An estimate of nothing left is a zero on the line rather than the absence of a question.
  it 'says nothing on a session with nothing left to do' do
    account_id = login
    workout_id = a_session(account_id, is_completed: true, completed_at: Time.now)

    get "/workouts/#{workout_id}/session"

    refute_match(/about \d+m left/, last_response.body)
  end
end

# The estimate is an answer about @sets, so it is wrong the moment they are reloaded. A tap
# applies itself and loads the session again, and a memo left over from before would still be
# counting the set that was just ticked off.
describe 'the estimate after a set is ticked off' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionLengths

  it 'shrinks' do
    account_id = login
    workout_id = a_session(account_id)
    set_id = DB[:sets].where(workout_id:).order(:id).get(:id)
    path = "/workouts/#{workout_id}/sets/#{set_id}/complete"

    get "/workouts/#{workout_id}/session"
    before = last_response.body[/about (\d+)m left/, 1].to_i
    post path, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) }

    assert_operator last_response.body[/about (\d+)m left/, 1].to_i, :<, before
  end
end

describe 'writing a week of a block with a time budget' do
  include Rack::Test::Methods
  include SessionLengths

  it 'names the overshoot rather than leaving it to be found in the gym' do
    minted = mint(scopes: %w[read write])
    program = a_long_block(minted.account_id, budget: 60)

    call_tool('generate_program_week', raw: minted.raw, arguments: { program_id: program.id })

    text = tool_result.dig('content', 0, 'text')

    assert_includes text, '60 minute budget'
    assert_match(/\d+ over/, text)
  end

  # It reports and does not refuse. Whether ninety minutes is wrong is a coaching question,
  # and the week still gets written.
  it 'still writes the week' do
    minted = mint(scopes: %w[read write])
    program = a_long_block(minted.account_id, budget: 60)

    call_tool('generate_program_week', raw: minted.raw, arguments: { program_id: program.id })

    assert_equal 1, Tectonic::Workout.where(account_id: minted.account_id).count
  end
end

describe 'writing a week the budget has nothing to say about' do
  include Rack::Test::Methods
  include SessionLengths

  # A block written with no clock in mind must not acquire an opinion about one.
  it 'says nothing about a budget on a block that set none' do
    minted = mint(scopes: %w[read write])
    program = a_long_block(minted.account_id, budget: nil)

    call_tool('generate_program_week', raw: minted.raw, arguments: { program_id: program.id })

    refute_includes tool_result.dig('content', 0, 'text'), 'budget'
  end

  it 'is quiet about a session that fits' do
    minted = mint(scopes: %w[read write])
    program = a_long_block(minted.account_id, budget: 300)

    call_tool('generate_program_week', raw: minted.raw, arguments: { program_id: program.id })

    refute_includes tool_result.dig('content', 0, 'text'), 'budget'
  end

  # Worth knowing on its own, and it is the number a caller needs before it can argue about
  # whether the budget is the thing that should move.
  it 'reports the length whether or not there is a budget' do
    minted = mint(scopes: %w[read write])
    program = a_long_block(minted.account_id, budget: nil)

    call_tool('generate_program_week', raw: minted.raw, arguments: { program_id: program.id })

    minutes = tool_result.dig('structuredContent', 'estimated_minutes').values

    assert_equal 1, minutes.length
    assert_operator minutes.first, :>, 60
  end
end

describe 'the budget on a block' do
  include Rack::Test::Methods
  include SessionLengths

  it 'can be set when the block is written, and reads back' do
    minted = mint(scopes: %w[read write])

    call_tool('create_program', raw: minted.raw,
                                arguments: { name: "Lunch block #{SecureRandom.hex(4)}", time_budget_minutes: 45,
                                             weeks: [{ days: [{ weekday: 1 }] }] })

    assert_equal 45, tool_result.dig('structuredContent', 'time_budget_minutes')
  end

  it 'can be set afterwards on a block that had none' do
    minted = mint(scopes: %w[read write])
    program = Tectonic::Program.create(account_id: minted.account_id, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true)

    call_tool('update_program', raw: minted.raw,
                                arguments: { program_id: program.id, time_budget_minutes: 75 })

    assert_equal 75, Tectonic::Program[program.id].time_budget_minutes
  end

  # Null is how a block goes back to having no opinion about the clock, which is what the
  # column being absent has always meant.
  it 'can be cleared' do
    minted = mint(scopes: %w[read write])
    program = Tectonic::Program.create(account_id: minted.account_id, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true, time_budget_minutes: 60)

    call_tool('update_program', raw: minted.raw,
                                arguments: { program_id: program.id, time_budget_minutes: nil })

    assert_nil Tectonic::Program[program.id].time_budget_minutes
  end
end

# Refused by name rather than left to programs_time_budget_in_range, which enforces it again:
# a constraint violation reaches a client as a database error and reads as the tool being
# broken.
describe 'a budget no session could meet' do
  include Rack::Test::Methods
  include SessionLengths

  it 'is refused, and the block is left alone' do
    minted = mint(scopes: %w[read write])
    program = Tectonic::Program.create(account_id: minted.account_id, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true)

    call_tool('update_program', raw: minted.raw, arguments: { program_id: program.id, time_budget_minutes: 2 })

    assert_includes tool_result.dig('content', 0, 'text'), 'out of range'
    assert_nil Tectonic::Program[program.id].time_budget_minutes
  end
end

# One query per movement rather than one per set, and the cache belongs to the lambda rather
# than to the module -- a module-level cache would be shared between accounts on one process,
# which for a number derived from one lifter's own sessions is a leak rather than a
# performance decision.
describe 'the turnaround lookup' do
  include SessionLengths

  it "measures the median from this lifter's own sessions" do
    account_id = an_account
    exercise = a_measured_movement(account_id)

    assert_equal 90, Tectonic::Turnarounds.lookup(account_id).call(exercise.id)
  end

  # Asserted by moving the data out from under it: a second call that went back to the
  # database would answer nil, and the cached one still answers ninety.
  it 'answers from its cache rather than asking again' do
    account_id = an_account
    exercise = a_measured_movement(account_id)
    counting = Tectonic::Turnarounds.lookup(account_id)
    counting.call(exercise.id)
    Tectonic::WorkoutSet.where(exercise_id: exercise.id).delete

    assert_equal 90, counting.call(exercise.id)
  end

  # nil is the answer for a movement with no history, and `||=` would go back to the database
  # on every set of it -- precisely the session where the lookup is most useless and most
  # repeated. Asserted the same way round: the cached nil survives data arriving.
  it 'caches the absence of an answer too' do
    account_id = an_account
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    counting = Tectonic::Turnarounds.lookup(account_id)
    counting.call(exercise.id)
    a_measured_movement(account_id)

    assert_nil counting.call(exercise.id)
  end
end

# The cache belongs to the lambda rather than to the module. A module-level one would be shared
# between accounts on one process, which for a number derived from one lifter's own sessions is
# a leak rather than a performance decision.
describe 'two lifters asking about the same movement' do
  include SessionLengths

  it "do not see one another's measurements" do
    mine = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    theirs = an_account
    exercise = a_measured_movement(mine)

    assert_equal 90, Tectonic::Turnarounds.lookup(mine).call(exercise.id)
    assert_nil Tectonic::Turnarounds.lookup(theirs).call(exercise.id)
  end
end

