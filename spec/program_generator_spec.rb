# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

# A one-day squat block: 4x5 to 155 on the bar, the same day written into every week.
# Warmup.ramp(155) gives four warmups and SetScheme four working sets, so a generated
# day holds eight sets.
def build_program(start_date: Date.new(2026, 8, 16), weeks: 1)
  account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  exercise_id = Tectonic::Exercise.insert(account_id:, name: 'Back Squat')
  program = Tectonic::Program.create(account_id:, name: "P#{SecureRandom.hex(4)}", block: 0,
                                     start_date:, preferred_reps: 3, is_ascending: true)
  (1..weeks).each { |number| build_week(program, exercise_id, number) }
  program
end

def build_week(program, exercise_id, number)
  week = Tectonic::ProgramWeek.create(program_id: program.id, number:)
  day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1, focus: 'Squat')
  Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 0,
                               sets: 4, reps: 5, top_weight: 155, is_barbell: true, is_main: true)
end

describe 'ProgramGenerator' do
  it 'writes a dated workout of warmups and working sets, planned and incomplete' do
    program = build_program
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    sets = Tectonic::WorkoutSet.where(workout_id: workout.id).all
    assert_equal Date.new(2026, 8, 17), workout.date.to_date # weekday 1 lands on the Monday
    assert_equal [4, 4], [sets.count(&:is_warmup), sets.reject(&:is_warmup).count]
    assert(sets.none?(&:is_completed))
    assert(sets.all? { |set| set.planned_weight == set.weight && set.planned_reps == set.reps })
  end

  it 'is idempotent: regenerating the week reuses the workout and adds no sets' do
    generator = Tectonic::ProgramGenerator.new(build_program)
    first = generator.generate(1).first
    before = Tectonic::WorkoutSet.where(workout_id: first.id).count
    assert_equal first.id, generator.generate(1).first.id
    assert_equal before, Tectonic::WorkoutSet.where(workout_id: first.id).count
  end
end

describe 'ProgramGenerator across a block' do
  it 'generates any week of the block, dating each from the block start' do
    generator = Tectonic::ProgramGenerator.new(build_program(weeks: 3))
    dates = (1..3).map { |number| generator.generate(number).first.date.to_date }
    assert_equal [Date.new(2026, 8, 17), Date.new(2026, 8, 24), Date.new(2026, 8, 31)], dates
  end

  # Idempotency used to key on the date alone, so a workout logged by hand on a day the
  # program also writes stood in for that day's session and it was never generated.
  it 'generates its day even when an unrelated workout is already logged that date' do
    program = build_program
    hand_logged = Tectonic::Workout.create(account_id: program.account_id, date: Date.new(2026, 8, 17))
    generated = Tectonic::ProgramGenerator.new(program).generate(1).first
    refute_equal hand_logged.id, generated.id
    assert_equal program.week(1).program_days.first.id, generated.program_day_id
    assert_nil hand_logged.refresh.program_day_id
  end

  it 'refuses a week the block does not have' do
    generator = Tectonic::ProgramGenerator.new(build_program(weeks: 2))
    error = assert_raises(ArgumentError) { generator.generate(3) }
    assert_includes error.message, 'no week 3'
  end
end

