# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

# A ramp scaled to the bar, and a lift that can overrule it. #451.
#
# The ramp came from a table of absolute thresholds -- 136 lb and 96 lb -- and could barely
# tell a 150 from a 235, when one is three times the empty bar and the other over five. Against
# a 45-minute cap each unnecessary rung across two or three barbell movements costs five to
# eight minutes.
#
# The count is a ratio now. It is also still convention rather than a result, which is the part
# #451 is careful about: "there is no good trial comparing three warmup sets to four. So this
# should be a configurable default, not a fixed algorithm asserting a right answer." So a lift
# can say a number, including zero.
module ArguableRamp
  def a_lift(account_id, top:, **extra)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: 'B', start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
    lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                        sets: 3, reps: 5, top_weight: top, progression: 'linear',
                                        is_main: true, is_barbell: true, **extra)
    [program, lift]
  end

  # The warmup weights a generated week actually wrote, which is the thing under test rather
  # than what Warmup returns on its own.
  def ramp_of(program)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    Tectonic::WorkoutSet.where(workout_id: workout.id, is_warmup: true).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }
  end
end

describe 'a ramp scaled to how far the top weight is above the bar' do
  include Rack::Test::Methods
  include ArguableRamp

  before { @token = mint(scopes: %w[read write]) }

  # #451's own numbers: a 150 is 3.3 times a 45 and wants about three stops; a 235 is 5.2 and
  # genuinely wants five. The old table gave both of them four.
  it 'gives a light lift fewer rungs than a heavy one' do
    light, = a_lift(@token.account_id, top: 150)
    heavy, = a_lift(@token.account_id, top: 235)

    assert_equal 3, ramp_of(light).length
    assert_equal 5, ramp_of(heavy).length
  end

  it 'always opens on the empty bar' do
    program, = a_lift(@token.account_id, top: 150)

    assert_equal 45, ramp_of(program).first
  end

  # Every rung lands on a weight the rack can build, which is #140's guarantee and is not
  # weakened by spacing them differently.
  it 'lands every rung on a loadable weight' do
    program, = a_lift(@token.account_id, top: 235)

    assert_empty(ramp_of(program).reject { |weight| (weight % 5).zero? })
  end
end

describe 'a lift that says how many rungs it wants' do
  include Rack::Test::Methods
  include ArguableRamp

  before { @token = mint(scopes: %w[read write]) }

  it 'takes the count it was written with' do
    program, = a_lift(@token.account_id, top: 235, warmup_sets: 2)

    assert_equal 2, ramp_of(program).length
  end

  # The opt-out #451 asks for outright, for "an accessory late in a session following the same
  # pattern as the lift before it".
  it 'writes no ramp at all where the lift asked for none' do
    program, = a_lift(@token.account_id, top: 235, warmup_sets: 0)

    assert_empty ramp_of(program)
  end
end

describe 'setting the count through the tools' do
  include Rack::Test::Methods
  include ArguableRamp

  before { @token = mint(scopes: %w[read write]) }

  it 'takes it on an edit and rewrites the session' do
    _program, lift = a_lift(@token.account_id, top: 235)
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: lift.id, warmup_sets: 0 })

    assert_equal 0, lift.refresh.warmup_sets
    assert_empty Tectonic::WorkoutSet
      .where(workout_id: Tectonic::Workout.where(program_day_id: lift.program_day_id).select(:id),
             is_warmup: true).all
  end

  # Null puts it back to the fitted count, which is how a lift stops having an opinion --
  # without it the answer would be unsayable once said.
  it 'goes back to the fitted count when cleared' do
    program, lift = a_lift(@token.account_id, top: 235, warmup_sets: 0)
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: lift.id, warmup_sets: nil })

    assert_nil lift.refresh.warmup_sets
    assert_equal 5, ramp_of(program.refresh).length
  end
end

# Refused by name rather than left to the check constraint, so a client gets a sentence instead
# of a database error -- the courtesy the rest and the target RPE already get on the way in.
describe 'a count nobody would ramp through' do
  include Rack::Test::Methods
  include ArguableRamp

  before { @token = mint(scopes: %w[read write]) }

  it 'refuses a count past the ceiling with a sentence' do
    _, lift = a_lift(@token.account_id, top: 235)
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: lift.id, warmup_sets: 12 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'Warmup sets'
  end
end

