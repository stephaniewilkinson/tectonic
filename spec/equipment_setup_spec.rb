# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/program_generator'
require_relative '../lib/tectonic/setup'
require 'securerandom'

# A prescription can say how the room is set up. #412.
#
# Chest-Supported DB Row was programmed with the note "incline bench" and nothing more. The
# lifter set 30 degrees, correctly, and had no way to know that was what was intended.
#
# Bench angle changes what a row trains -- shallow loads the lats, past about 45 degrees it
# becomes a rear-delt movement -- so it is a programming variable rather than a preference.
# Rack heights matter more than they look too: re-unracking mid-warmup wastes several minutes,
# which is expensive against the time budget #408 just gave a block.
module EquipmentSetup
  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')

  # A one-week block whose only lift carries a setup, heavy enough that Warmup puts a ramp
  # above it -- the ramp being the half that matters most here.
  def a_block(account_id, **setup)
    exercise = Tectonic::Exercise.create(account_id:, name: "Row #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: monday, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: monday.wday)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 5, top_weight: 225, progression: 'linear',
                                 is_barbell: true, is_main: true, **setup)
    [program, exercise]
  end

  def monday = Date.today - ((Date.today.wday - 1) % 7)

  def generated(program)
    Tectonic::ProgramGenerator.new(program).generate(1)
    Tectonic::WorkoutSet.where(workout_id: Tectonic::Workout.where(account_id: program.account_id)
                                                            .select(:id)).all
  end

  def a_set(account_id, **overrides)
    exercise = Tectonic::Exercise.create(account_id:, name: "Row #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    set_id = DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 100, reps: 10,
                                is_warmup: false, is_completed: false, is_barbell: true }.merge(overrides))
    [workout_id, set_id, exercise]
  end
end

describe 'how a setup reads' do
  include EquipmentSetup

  it 'names the bench angle with its unit' do
    assert_equal 'bench 30°', Tectonic::Setup.phrase(bench_angle_degrees: 30)
  end

  # "-15°" on a row that also holds weights and rep counts is a number somebody has to work out
  # is not a subtraction.
  it 'says decline in words rather than as a minus sign' do
    assert_equal 'bench 15° decline', Tectonic::Setup.phrase(bench_angle_degrees: -15)
  end

  # Zero is flat and is a real instruction. The column is nullable precisely so that "flat" and
  # "nobody said" stay different answers.
  it 'reads zero as flat rather than as nothing' do
    assert_equal 'flat bench', Tectonic::Setup.phrase(bench_angle_degrees: 0)
  end

  # A lifter sets the bench up, gets under the bar, and sets the safeties. Alphabetical order
  # would put the bench between the two rack numbers that are read together.
  it 'reads in the order the room is actually set up' do
    assert_equal 'bench 30°, J-hooks 11, safeties 7',
                 Tectonic::Setup.phrase(bench_angle_degrees: 30, rack_hole: 11, safety_hole: 7)
  end

  # Almost every set has no setup, and a row saying "bench —" on every barbell curl would be
  # worse than the note this replaces.
  it 'says nothing where nothing was prescribed' do
    assert_nil Tectonic::Setup.phrase(bench_angle_degrees: nil, rack_hole: nil, safety_hole: nil)
  end
end

describe 'a block that prescribes a setup' do
  include EquipmentSetup

  it 'carries it onto the sets it generates' do
    program, = a_block(an_account, bench_angle_degrees: 30, rack_hole: 11, safety_hole: 7)

    working = generated(program).reject(&:is_warmup)

    refute_empty working
    assert(working.all? { |set| set.bench_angle_degrees == 30 && set.rack_hole == 11 })
  end

  # The one instruction on a lift that is *more* wanted on a ramp than under it: the whole cost
  # the issue names is getting under the bar at the wrong J-hook height and having to re-unrack
  # mid-warmup, which by definition happens on the first rung.
  it 'carries it onto the warmup ramp too, unlike an effort or a rest' do
    program, = a_block(an_account, bench_angle_degrees: 30, rack_hole: 11)

    warmups = generated(program).select(&:is_warmup)

    refute_empty warmups, 'a 225 lb top set should have a ramp, or this asserts nothing'
    assert(warmups.all? { |set| set.rack_hole == 11 })
  end

  it 'leaves the columns empty where the block said nothing' do
    program, = a_block(an_account)

    assert(generated(program).all? { |set| set.bench_angle_degrees.nil? })
  end
end

describe 'the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include EquipmentSetup

  it 'says how to set the room up' do
    account_id = login
    workout_id, = a_set(account_id, bench_angle_degrees: 30, rack_hole: 11, safety_hole: 7)

    get "/workouts/#{workout_id}/session"

    assert_includes last_response.body, 'bench 30°, J-hooks 11, safeties 7'
  end

  it 'says nothing about a set with no setup' do
    account_id = login
    workout_id, = a_set(account_id)

    get "/workouts/#{workout_id}/session"

    refute_includes last_response.body, 'J-hooks'
  end

  # The screen is polled, and a block represcribed at a different bench angle would otherwise
  # leave a lifter setting the bench to a number the row behind the page no longer holds.
  it 'is part of what the poll calls a change' do
    account_id = login
    workout_id, set_id, = a_set(account_id)
    workout = Tectonic::Workout[workout_id]
    before = workout.session_fingerprint

    Tectonic::WorkoutSet[set_id].update(bench_angle_degrees: 30)

    refute_equal before, workout.session_fingerprint
  end
end

# #406's rule, applied to the new columns. A bench angle left behind on a movement that does
# not use a bench is that bug wearing different numbers, on the one line of the row a lifter
# acts on before touching the bar.
describe 'a set swapped onto another movement' do
  include Rack::Test::Methods
  include EquipmentSetup

  it 'leaves the old lift\'s setup behind with its prescription' do
    minted = mint(scopes: %w[read write])
    _workout_id, set_id, = a_set(minted.account_id, bench_angle_degrees: 30, rack_hole: 11)

    call_tool('update_set', raw: minted.raw,
                            arguments: { set_id:, exercise: "Plank #{SecureRandom.hex(4)}" })

    moved = Tectonic::WorkoutSet[set_id]

    assert_nil moved.bench_angle_degrees
    assert_nil moved.rack_hole
  end
end

describe 'a setup written over the connector' do
  include Rack::Test::Methods
  include EquipmentSetup

  def an_empty_day(account_id)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
  end

  it 'is stored on the lift and read back' do
    minted = mint(scopes: %w[read write])

    call_tool('add_program_lift', raw: minted.raw,
                                  arguments: { program_day_id: an_empty_day(minted.account_id).id,
                                               exercise: "Row #{SecureRandom.hex(4)}", sets: 3,
                                               reps: 10, top_weight: 60, bench_angle_degrees: 30 })

    assert_equal 30, tool_result.dig('structuredContent', 'bench_angle_degrees')
  end
end

# Refused by name rather than left to the check constraints, which enforce the same ranges: a
# constraint violation reaches a client as a database error and reads as the tool being broken.
describe 'a setup nothing in a gym could be set to' do
  include Rack::Test::Methods
  include EquipmentSetup

  def an_empty_day(account_id)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
  end

  it 'refuses an angle no bench has, and says the range' do
    minted = mint(scopes: %w[read write])

    call_tool('add_program_lift', raw: minted.raw,
                                  arguments: { program_day_id: an_empty_day(minted.account_id).id,
                                               exercise: "Row #{SecureRandom.hex(4)}", sets: 3,
                                               reps: 10, top_weight: 60, bench_angle_degrees: 120 })

    assert_includes tool_result.dig('content', 0, 'text'), 'Bench angle 120 is out of range'
  end

  it 'refuses a hole no rack has' do
    minted = mint(scopes: %w[read write])

    call_tool('add_program_lift', raw: minted.raw,
                                  arguments: { program_day_id: an_empty_day(minted.account_id).id,
                                               exercise: "Row #{SecureRandom.hex(4)}", sets: 3,
                                               reps: 10, top_weight: 60, rack_hole: 0 })

    assert_includes tool_result.dig('content', 0, 'text'), 'J-hook hole 0 is out of range'
  end
end

# An assistant asked to write next week's block has to be able to see that this row was done on
# a 30 degree bench, or it writes the same movement with nothing said about the bench and the
# lifter is back to guessing -- which is the whole of the issue.
describe 'a session read back over the connector' do
  include Rack::Test::Methods
  include EquipmentSetup

  it 'says the setup in the prose and carries the numbers in the payload' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_set(minted.account_id, bench_angle_degrees: 30, rack_hole: 11)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), '(bench 30°, J-hooks 11)'
    assert_equal 30, tool_result.dig('structuredContent', 'sets', 0, 'bench_angle_degrees')
  end

  it 'says nothing extra about a set with no setup' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_set(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    refute_includes tool_result.dig('content', 0, 'text'), 'J-hooks'
  end
end

