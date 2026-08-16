# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

# A one-day squat program: 4x5 to 155 on the bar. Warmup.ramp(155) gives four
# warmups and SetScheme four working sets, so a generated day holds eight sets.
def build_program
  account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  exercise_id = Tectonic::Exercise.insert(account_id:, name: 'Back Squat')
  program = Tectonic::Program.create(account_id:, name: "P#{SecureRandom.hex(4)}", block: 0,
                                     week: 1, preferred_reps: 3, is_ascending: true)
  day = Tectonic::ProgramDay.create(program_id: program.id, weekday: 1, focus: 'Squat')
  Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 0,
                               sets: 4, reps: 5, top_weight: 155, is_barbell: true, is_main: true)
  program
end

describe 'ProgramGenerator' do
  it 'writes a dated workout of warmups and working sets, planned and incomplete' do
    program = build_program
    workout = Tectonic::ProgramGenerator.new(program).generate(Date.new(2026, 8, 16)).first
    sets = Tectonic::Set.where(workout_id: workout.id).all
    assert_equal Date.new(2026, 8, 17), workout.date.to_date # weekday 1 lands on the Monday
    assert_equal [4, 4], [sets.count(&:is_warmup), sets.reject(&:is_warmup).count]
    assert(sets.none?(&:is_completed))
    assert(sets.all? { |set| set.planned_weight == set.weight && set.planned_reps == set.reps })
  end

  it 'is idempotent: regenerating the week reuses the workout and adds no sets' do
    generator = Tectonic::ProgramGenerator.new(build_program)
    first = generator.generate(Date.new(2026, 8, 16)).first
    before = Tectonic::Set.where(workout_id: first.id).count
    assert_equal first.id, generator.generate(Date.new(2026, 8, 16)).first.id
    assert_equal before, Tectonic::Set.where(workout_id: first.id).count
  end
end

