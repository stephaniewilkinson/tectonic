# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_generator'
require_relative '../lib/tectonic/training_max'
require 'securerandom'

# A percentage block takes all its percentages of one number. #291.
#
# The max used to be resolved at generation, so a block generated week by week took each
# week's percentage of whatever the max was that day -- and a PR mid-block moved the
# denominator under the weeks that had not been written yet. The wave stopped being a wave.
#
# It is read as of the block's start date now, which is what 5/3/1, Juggernaut, Sheiko and
# block periodization all do: the reference is constant for the cycle and moves at a control
# point, not on a good Tuesday.
module BlockDenominator
  # A block of `weeks` weeks, one day each, one lift priced as a percentage. Dated in the
  # past so that lifting can happen "after" it started without the week arithmetic running
  # into the future.
  def percentage_block(account_id, exercise, percent:, weeks: 3, started: Date.today - 21)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}", start_date: started)
    (1..weeks).each do |number|
      week = Tectonic::ProgramWeek.create(program_id: program.id, number:)
      day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: started.wday, focus: 'Squat')
      Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                   sets: 3, reps: 5, percent_of_max: percent, progression: 'percent',
                                   is_barbell: true, is_main: true)
    end
    program
  end

  def movement(account_id)
    Tectonic::Exercise.create(name: "Lift #{SecureRandom.hex(4)}", account_id:, is_barbell: true)
  end

  # A completed set on a date, which is what the derived max reads.
  def lifted(account_id, exercise, weight:, on:, reps: 5)
    workout_id = DB[:workouts].insert(account_id:, date: on)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, reps:,
                     is_warmup: false, is_completed: true, is_barbell: true)
  end

  def top_of(program, number)
    workout = Tectonic::ProgramGenerator.new(program).generate(number).first
    Tectonic::WorkoutSet.where(workout_id: workout.id, is_warmup: false).map(&:weight).max
  end
end

describe 'a percentage block whose lifter PRs halfway through' do
  include BlockDenominator

  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = movement(@account_id)
    @started = Date.today - 21
    # Lifting before the block opens, which is what its denominator is read from.
    lifted(@account_id, @exercise, weight: 200, on: @started - 7)
    @program = percentage_block(@account_id, @exercise, percent: 80, started: @started)
  end

  # The whole of #291. Week one is generated, the lifter PRs, and week two must still be
  # 80% of the number week one was 80% of.
  it 'takes every week of the same number' do
    first = top_of(@program, 1)
    lifted(@account_id, @exercise, weight: 260, on: @started + 3)

    assert_equal first, top_of(@program, 2), 'a PR mid-block moved the denominator'
  end

  # The same fact stated the way it goes wrong: a deload is only a deload relative to a
  # fixed reference. Against a moving one it can come out heavier than the weeks it recovers
  # from, which is the failure that is easiest to miss because the number looks reasonable.
  it 'keeps a deload lighter than the working weeks it follows' do
    working = top_of(@program, 1)
    lifted(@account_id, @exercise, weight: 300, on: @started + 3)
    Tectonic::ProgramWeek.where(program_id: @program.id, number: 3).update(is_deload: true)

    assert_operator top_of(@program, 3), :<, working
  end
end

# Lifting done before the block opened is what it is built on, and lifting done after it
# opened belongs to the next block.
describe 'which lifting a block reads its max from' do
  include BlockDenominator

  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = movement(@account_id)
    @started = Date.today - 21
  end

  it 'reads what was lifted before it started' do
    lifted(@account_id, @exercise, weight: 200, on: @started - 7)
    program = percentage_block(@account_id, @exercise, percent: 80, started: @started)
    prescribed = top_of(program, 1)

    assert_operator prescribed, :>, 0
  end

  # A block opened before the movement was ever trained still refuses, because as of its
  # start date there was nothing to read -- which is the same refusal as before, arrived at
  # by the date rather than by the absence of rows.
  it 'refuses when nothing had been lifted by the day it opened' do
    lifted(@account_id, @exercise, weight: 200, on: @started + 3)
    program = percentage_block(@account_id, @exercise, percent: 80, started: @started)

    error = assert_raises(ArgumentError) { top_of(program, 1) }
    assert_match(/no training max/i, error.message)
  end
end

# A stated max was never affected by any of this: TrainingMax.for passes `on` to the
# derivation and not to the lookup, because a standing instruction has no history to be
# as-of. Worth a test, since #291 is the change that makes that asymmetry load-bearing.
describe 'a block priced off a stated max' do
  include BlockDenominator

  it 'is unmoved by lifting during the block' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = movement(account_id)
    started = Date.today - 21
    Tectonic::TrainingMax.replace(account_id, exercise.id, 300)
    program = percentage_block(account_id, exercise, percent: 80, started:)

    first = top_of(program, 1)
    lifted(account_id, exercise, weight: 400, on: started + 3)

    assert_equal 240, first, '80% of a stated 300'
    assert_equal first, top_of(program, 2)
  end
end

