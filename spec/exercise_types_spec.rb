# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'
require 'date'

# How a movement is done: whether it carries weight, whether it is counted in reps or in
# time, and whether that count is per side. Three independent facts, eight combinations,
# and until now only rep-counted bilateral weighted work could be written down. A plank
# had to be written as `top_weight: 0`, which is truthy in Ruby and so passed as a real
# starting load -- the linear rule then added an increment every week the lifter completed
# it, and a plank became a 10 lb weighted plank in three weeks.
module ExerciseTypes
  def an_account
    DB[:accounts].insert(email: "types-#{SecureRandom.hex(4)}@example.com",
                         password_hash: 'x', created_on: Time.now)
  end

  def a_movement(account_id, barbell: false, **defaults)
    Tectonic::Exercise.create({ account_id:, name: "Move #{SecureRandom.hex(4)}",
                                is_barbell: barbell }.merge(defaults))
  end

  def a_block(account_id, weeks: 1, start: Date.today - 21)
    Tectonic::Program.create(account_id:, name: 'Block', start_date: start, is_ascending: true).tap do |program|
      weeks.times { |index| Tectonic::ProgramWeek.create(program_id: program.id, number: index + 1) }
    end
  end

  def a_day(program, number = 1)
    week = program.program_weeks_dataset.where(number:).first
    Tectonic::ProgramDay.create(program_week_id: week.id, weekday: program.start_date.wday)
  end

  def sets_for(account_id, exercise)
    Tectonic::WorkoutSet.where(exercise_id: exercise.id,
                               workout_id: Tectonic::Workout.where(account_id:).select(:id)).order(:id).all
  end

  def write(account_id, day, exercise, **attributes)
    context = Tectonic::MCP::RequestContext.new(account_id:, email: nil, scopes: [], application_id: nil)
    Tectonic::MCP::Tools::ProgramWriter.lift(context, day,
                                             { exercise: exercise.name, sets: 3 }.merge(attributes))
  end
end

describe 'a movement that carries no weight' do
  include ExerciseTypes

  before do
    @account_id = an_account
    @plank = a_movement(@account_id)
    @program = a_block(@account_id)
    write(@account_id, a_day(@program), @plank, reps: 10, is_weighted: false)
    Tectonic::ProgramGenerator.new(@program).generate(1)
  end

  it 'generates with no weight at all rather than a weight of zero' do
    assert_equal [nil], sets_for(@account_id, @plank).map(&:weight).uniq
  end

  it 'draws no warmup ramp, because there is nothing to ramp up to' do
    assert_empty sets_for(@account_id, @plank).select(&:is_warmup)
  end
end

# The bug the old workaround caused, pinned so it cannot come back.
describe 'an unweighted lift across three weeks' do
  include ExerciseTypes

  it 'still weighs nothing in week three' do
    account_id = an_account
    plank = a_movement(account_id)
    program = a_block(account_id, weeks: 3)
    prescribed = (1..3).map do |number|
      write(account_id, a_day(program, number), plank, reps: 10, is_weighted: false)
      Tectonic::ProgramGenerator.new(program).generate(number)
      fresh = sets_for(account_id, plank).reject(&:is_completed)
      fresh.each { |set| set.update(is_completed: true) }
      fresh.map(&:weight).uniq
    end

    assert_equal [[nil], [nil], [nil]], prescribed
  end
end

describe 'a movement counted in time' do
  include ExerciseTypes

  before do
    @account_id = an_account
    @plank = a_movement(@account_id)
    @program = a_block(@account_id)
    write(@account_id, a_day(@program), @plank, measure: 'time', duration_seconds: 60, is_weighted: false)
    Tectonic::ProgramGenerator.new(@program).generate(1)
  end

  it 'carries seconds rather than a rep count it never had' do
    held = sets_for(@account_id, @plank)

    assert_equal [60], held.map(&:duration_seconds).uniq
    assert_equal [nil], held.map(&:reps).uniq
    assert(held.all?(&:timed?))
  end

  # A held position has nothing to ramp up to, and a ladder of durations is not a warmup.
  it 'is written flat, with no ramp' do
    assert_empty sets_for(@account_id, @plank).select(&:is_warmup)
  end
end

describe 'a weighted timed movement' do
  include ExerciseTypes

  it 'holds one load for its whole duration' do
    account_id = an_account
    carry = a_movement(account_id)
    program = a_block(account_id)
    write(account_id, a_day(program), carry, measure: 'time', duration_seconds: 45, top_weight: 70)
    Tectonic::ProgramGenerator.new(program).generate(1)

    held = sets_for(account_id, carry)

    assert_equal [70], held.map(&:weight).uniq
    assert_equal [45], held.map(&:duration_seconds).uniq
  end
end

describe 'a movement counted per side' do
  include ExerciseTypes

  it 'says so on every set it writes, and counts as the work that happened' do
    account_id = an_account
    split = a_movement(account_id)
    program = a_block(account_id)
    write(account_id, a_day(program), split, reps: 8, top_weight: 95, is_per_side: true)
    Tectonic::ProgramGenerator.new(program).generate(1)

    working = sets_for(account_id, split).reject(&:is_warmup)

    assert(working.all?(&:is_per_side))
    assert_equal [16], working.map(&:counted_reps).uniq
  end
end

# The movement carries the usual way; a prescription may say otherwise for one block.
describe 'the default a movement carries' do
  include ExerciseTypes

  before do
    @account_id = an_account
    @program = a_block(@account_id)
  end

  it 'is taken when the prescription says nothing' do
    plank = a_movement(@account_id, default_measure: 'time', default_is_weighted: false,
                                    default_is_per_side: true)
    lift = write(@account_id, a_day(@program), plank, duration_seconds: 30)

    assert_equal :time, lift.measure
    refute lift.is_weighted
    assert lift.is_per_side
  end

  it 'is overridden where the prescription does say' do
    press = a_movement(@account_id, default_is_per_side: false)
    lift = write(@account_id, a_day(@program), press, reps: 8, top_weight: 40, is_per_side: true)

    assert lift.is_per_side
  end
end

describe 'a prescription the writer will not accept' do
  include ExerciseTypes

  before do
    @account_id = an_account
    @day = a_day(a_block(@account_id))
    @movement = a_movement(@account_id)
  end

  def refusal(**attributes)
    assert_raises(Tectonic::MCP::Tool::Refusal) { write(@account_id, @day, @movement, **attributes) }
  end

  # The workaround this replaces, refused by name so a model is told what to write.
  it 'refuses a lift written at zero pounds' do
    assert_includes refusal(reps: 10, top_weight: 0).message, 'is_weighted'
  end

  it 'refuses a lift that is both unweighted and priced' do
    refusal(reps: 10, is_weighted: false, top_weight: 95)
    refusal(reps: 10, is_weighted: false, percent_of_max: 70)
  end

  it 'refuses a timed lift with no duration, and a counted lift with no reps' do
    assert_includes refusal(measure: 'time', is_weighted: false).message, 'duration_seconds'
    assert_includes refusal(is_weighted: false).message, 'reps'
  end

  it 'refuses a measure that is neither reps nor time' do
    assert_includes refusal(reps: 10, is_weighted: false, measure: 'furlongs').message, 'furlongs'
  end
end

# The database holds these invariants for anything that writes to it, not only for the
# code paths that go through the writer.
describe 'the shape constraints' do
  include ExerciseTypes

  before do
    @account_id = an_account
    @day = a_day(a_block(@account_id))
    @movement = a_movement(@account_id)
  end

  def row(**attributes)
    Tectonic::ProgramLift.create({ program_day_id: @day.id, exercise_id: @movement.id, position: 0,
                                   sets: 3, reps: 10, is_main: false, is_barbell: false,
                                   is_weighted: true, progression: 'linear' }.merge(attributes))
  end

  it 'refuses a row carrying both a rep count and a duration' do
    assert_raises(Sequel::CheckConstraintViolation) { row(measure: 'time', duration_seconds: 60) }
  end

  it 'refuses a row that is unweighted and priced' do
    assert_raises(Sequel::CheckConstraintViolation) do
      row(is_weighted: false, progression: nil, top_weight: 95)
    end
  end

  # Weighted and progression answer the same question from two directions, so the table
  # keeps them agreeing rather than trusting every writer to.
  it 'refuses a weighted row with no rule, and an unweighted row with one' do
    assert_raises(Sequel::CheckConstraintViolation) { row(is_weighted: true, progression: nil) }
    assert_raises(Sequel::CheckConstraintViolation) { row(is_weighted: false, progression: 'linear') }
  end
end

