# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/program_generator'
require 'securerandom'

# A rep can be done under commands, and now there is somewhere to say so. #311.
#
# At a meet the bench press is three instructions -- start, press, rack -- and a lift that
# was never in doubt gets three red lights for the timing of it. The only way to record that
# until now was to invent a second movement, which splits the history so `exercise_history`
# for Bench Press cannot see the commanded work, and which cannot express a commanded set
# *inside* an ordinary lift -- the top single commanded, the back-offs not -- which is how
# almost everybody trains it.
module CommandedReps
  # A one-week block whose only lift is prescribed under commands, heavy enough that Warmup
  # puts a ramp above it. The ramp is the interesting half: the database permits a commanded
  # warmup and the generator still declines to write one, and those two facts have to be
  # asserted separately or one of them will quietly become the other.
  def commanded_block(account_id, is_commanded: true)
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: "Meet prep #{SecureRandom.hex(4)}",
                                       start_date: monday, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: monday.wday)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 1, top_weight: 225, progression: 'linear',
                                 is_barbell: true, is_main: true, is_commanded:)
    [program, exercise]
  end

  def monday = Date.today - ((Date.today.wday - 1) % 7)

  def generated_sets(program)
    Tectonic::ProgramGenerator.new(program).generate(1)
    Tectonic::WorkoutSet.where(workout_id: Tectonic::Workout.where(account_id: program.account_id)
                                                            .select(:id)).all
  end

  # A plain logged set, for the paths that do not involve a block at all.
  def a_set(account_id, **overrides)
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    set_id = DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 225, reps: 1,
                                is_warmup: false, is_completed: true, is_barbell: true }.merge(overrides))
    [workout_id, set_id, exercise]
  end

  # A plank: the shape the constraint refuses, which three separate paths have to decline in
  # three separate ways.
  def a_timed_set(account_id)
    a_set(account_id, measure: 'time', reps: nil, duration_seconds: 60, weight: nil)
  end

  # A day with nothing in it yet, for the tools that write a lift into one.
  def an_empty_day(account_id)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
  end
end

describe 'a block that prescribes commands' do
  include CommandedReps

  before { @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x') }

  it 'carries them onto every working set it generates' do
    program, = commanded_block(@account_id)

    working = generated_sets(program).reject(&:is_warmup)

    refute_empty working
    assert(working.all?(&:is_commanded), 'the prescription did not reach the rows the lifter reads')
  end

  # The generator's own choice rather than the database's, which is why it is asserted here
  # and contradicted two describes down. A ramp is computed -- the rungs are fractions of the
  # top set, chosen by Warmup rather than written by anybody -- so commands on one would be an
  # instruction the block never gave.
  it 'leaves the computed ramp above them alone' do
    program, = commanded_block(@account_id)

    warmups = generated_sets(program).select(&:is_warmup)

    refute_empty warmups, 'a 225 lb top single should have a ramp, or this asserts nothing'
    refute(warmups.any?(&:is_commanded))
  end

  it 'writes nothing when the block does not ask for it' do
    program, = commanded_block(@account_id, is_commanded: false)

    refute(generated_sets(program).any?(&:is_commanded))
  end
end

describe 'the session screen on a commanded set' do
  include Rack::Test::Methods
  include RouteOwnership
  include CommandedReps

  it 'says so on the row' do
    account_id = login
    workout_id, = a_set(account_id, is_commanded: true)

    get "/workouts/#{workout_id}/session"

    assert_includes last_response.body, 'commanded'
  end

  # Almost every set is an ordinary one, and a stray "commanded" on a set of curls would be
  # worse than the silence it replaces.
  it 'says nothing extra about an ordinary set' do
    account_id = login
    workout_id, = a_set(account_id)

    get "/workouts/#{workout_id}/session"

    refute_includes last_response.body, 'commanded'
  end

  # The screen is polled, and the poll answers 204 when the session has not moved. A column
  # drawn on the row and missing from the fingerprint means a block represcribed under
  # commands leaves the phrase on the page disagreeing with the row behind it.
  it 'is part of what the poll calls a change' do
    account_id = login
    workout_id, set_id, = a_set(account_id)
    workout = Tectonic::Workout[workout_id]
    before = workout.session_fingerprint

    Tectonic::WorkoutSet[set_id].update(is_commanded: true)

    refute_equal before, workout.session_fingerprint
  end
end

describe 'the set edit form' do
  include Rack::Test::Methods
  include RouteOwnership
  include CommandedReps

  it 'saves the box when it is ticked' do
    account_id = login
    workout_id, set_id, exercise = a_set(account_id)
    path = "/workouts/#{workout_id}/sets/#{set_id}"

    post path, { weight: 225, reps: 1, exercise_id: exercise.id, is_commanded: '1',
                 '_csrf' => token_for_form("#{path}/edit", path) }

    assert Tectonic::WorkoutSet[set_id].is_commanded
  end

  it 'clears it when it is not' do
    account_id = login
    workout_id, set_id, exercise = a_set(account_id, is_commanded: true)
    path = "/workouts/#{workout_id}/sets/#{set_id}"

    post path, { weight: 225, reps: 1, exercise_id: exercise.id,
                 '_csrf' => token_for_form("#{path}/edit", path) }

    refute Tectonic::WorkoutSet[set_id].is_commanded
  end
end

# Commands bracket a rep, so a movement held for time has no rep for them to bracket and the
# database refuses the row outright.
describe 'the set edit form on a set held for time' do
  include Rack::Test::Methods
  include RouteOwnership
  include CommandedReps

  # A box that could only ever produce a 500 is worse than no box.
  it 'does not draw the box at all' do
    account_id = login
    workout_id, set_id, = a_timed_set(account_id)

    get "/workouts/#{workout_id}/sets/#{set_id}/edit"

    refute_includes last_response.body, 'is_commanded'
  end

  # And the post is ignored the same way, because a post is a post. Without the guard this is
  # a check violation, which reaches a person as a 500 page and a lost edit -- #213's shape,
  # and the reason that guard is a method rather than the bare parameter the two checkboxes
  # beside it get.
  it 'ignores a hand-made post claiming the set was commanded' do
    account_id = login
    workout_id, set_id, exercise = a_timed_set(account_id)
    path = "/workouts/#{workout_id}/sets/#{set_id}"

    post path, { duration_seconds: 60, exercise_id: exercise.id, is_commanded: '1',
                 '_csrf' => token_for_form("#{path}/edit", path) }

    assert_equal 302, last_response.status
    refute Tectonic::WorkoutSet[set_id].is_commanded
  end
end

describe 'a set logged over the connector' do
  include Rack::Test::Methods
  include CommandedReps

  it 'can say it was commanded' do
    minted = mint(scopes: %w[read write])

    call_tool('create_set', raw: minted.raw,
                            arguments: { exercise: "Bench #{SecureRandom.hex(4)}", weight: 225,
                                         reps: 1, is_commanded: true })

    assert_includes tool_result.dig('content', 0, 'text'), '225x1 commanded'
    assert tool_result.dig('structuredContent', 'is_commanded')
  end

  it 'is not commanded unless it says so' do
    minted = mint(scopes: %w[read write])

    call_tool('create_set', raw: minted.raw,
                            arguments: { exercise: "Bench #{SecureRandom.hex(4)}", weight: 225, reps: 1 })

    refute tool_result.dig('structuredContent', 'is_commanded')
  end

  # Remembering after the session that the top single was commanded is the ordinary way
  # round, so this is not behind `confirm` -- it says how the set was performed rather than
  # overwriting anything that was measured.
  it 'can be marked commanded afterwards without confirm' do
    minted = mint(scopes: %w[read write])
    _workout_id, set_id, = a_set(minted.account_id)

    call_tool('update_set', raw: minted.raw, arguments: { set_id:, is_commanded: true })

    assert Tectonic::WorkoutSet[set_id].is_commanded
  end
end

describe 'reading a commanded session back' do
  include Rack::Test::Methods
  include CommandedReps

  it 'says so in the prose and in the payload' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_set(minted.account_id, is_commanded: true)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), '225x1 commanded'
    assert tool_result.dig('structuredContent', 'sets', 0, 'is_commanded')
  end
end

# Refused by name rather than left to the check constraint, which enforces it again. A
# constraint violation reaches a client as a database error and reads as the tool being
# broken; this names the field and says what to do about it.
describe 'commands somewhere they cannot mean anything' do
  include Rack::Test::Methods
  include CommandedReps

  it 'refuses a timed lift prescribed under commands, and says why' do
    minted = mint(scopes: %w[read write])

    call_tool('add_program_lift', raw: minted.raw,
                                  arguments: { program_day_id: an_empty_day(minted.account_id).id,
                                               exercise: "Plank #{SecureRandom.hex(4)}",
                                               sets: 3, measure: 'time', duration_seconds: 60,
                                               is_weighted: false, is_commanded: true })

    assert_includes tool_result.dig('content', 0, 'text'), 'counted in reps'
  end

  # The other direction, which is the one a check constraint would have caught too late: a
  # lift already prescribed under commands, edited to be held for time.
  it 'refuses to hold a commanded lift for time instead' do
    minted = mint(scopes: %w[read write])
    _program, = commanded_block(minted.account_id)
    lift = Tectonic::ProgramLift.order(:id).last

    call_tool('update_program_lift', raw: minted.raw,
                                     arguments: { program_lift_id: lift.id, measure: 'time',
                                                  duration_seconds: 60 })

    assert_includes tool_result.dig('content', 0, 'text'), 'counted in reps'
    assert Tectonic::ProgramLift[lift.id].is_commanded, 'the refusal has to leave the lift as it was'
  end
end

describe 'marking a set held for time as commanded' do
  include Rack::Test::Methods
  include CommandedReps

  it 'is refused, and the set is left as it was' do
    minted = mint(scopes: %w[read write])
    _workout_id, set_id, = a_timed_set(minted.account_id)

    call_tool('update_set', raw: minted.raw, arguments: { set_id:, is_commanded: true })

    assert_includes tool_result.dig('content', 0, 'text'), 'counted in reps'
    refute Tectonic::WorkoutSet[set_id].is_commanded
  end
end

# The database is deliberately wider than the generator, and the difference is not an
# oversight. Practising the start command on the last heavy single before openers is real
# meet preparation and is a warmup by every definition this app has, so a lifter ticking the
# box on their own warmup row is recording something true.
describe 'a warmup the lifter says was commanded' do
  include CommandedReps

  it 'is accepted, even though the generator would never write one' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    _workout_id, set_id, = a_set(account_id, is_warmup: true)

    Tectonic::WorkoutSet[set_id].update(is_commanded: true)

    assert Tectonic::WorkoutSet[set_id].is_commanded
  end
end

