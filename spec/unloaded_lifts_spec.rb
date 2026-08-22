# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'
require 'date'

# Work carrying no external load: a plank, a band pull-apart, a walk. There was no way to
# write one, so it was written as `top_weight: 0` -- and zero is truthy in Ruby, which is
# what made that workaround dangerous rather than merely untidy. A zero passed as a real
# starting load, a completed set counted as meeting it, and the linear rule added an
# increment: a plank generated at 0, then 5, then 10.
module UnloadedLifts
  def an_account
    email = "unloaded-#{SecureRandom.hex(4)}@example.com"
    DB[:accounts].insert(email:, password_hash: 'x', created_on: Time.now)
  end

  def a_movement(account_id, barbell: false)
    Tectonic::Exercise.create(account_id:, name: "Plank #{SecureRandom.hex(4)}", is_barbell: barbell)
  end

  # A block with one lift in each of its weeks, written the way the generator reads them.
  def a_block(account_id, weeks:, start: Date.today - 21)
    Tectonic::Program.create(account_id:, name: 'Block', start_date: start, is_ascending: true).tap do |program|
      weeks.times { |index| Tectonic::ProgramWeek.create(program_id: program.id, number: index + 1) }
    end
  end

  def a_lift(program, number, exercise, **attributes)
    week = program.program_weeks_dataset.where(number:).first
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: program.start_date.wday)
    Tectonic::ProgramLift.create({ program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                   sets: 3, reps: 10, is_main: false }.merge(attributes))
  end

  def sets_for(account_id, exercise)
    Tectonic::Set.where(exercise_id: exercise.id,
                        workout_id: Tectonic::Workout.where(account_id:).select(:id)).all
  end
end

describe 'a lift that carries no external load' do
  include UnloadedLifts

  before do
    @account_id = an_account
    @plank = a_movement(@account_id)
    @program = a_block(@account_id, weeks: 1)
    a_lift(@program, 1, @plank, progression: 'unloaded', top_weight: nil, is_barbell: false)
    Tectonic::ProgramGenerator.new(@program).generate(1)
  end

  it 'generates its sets with no weight at all rather than a weight of zero' do
    weights = sets_for(@account_id, @plank).map(&:weight)

    assert_equal 3, weights.length
    assert_equal [nil], weights.uniq
  end

  it 'draws no warmup ramp, because there is nothing to ramp up to' do
    assert_empty sets_for(@account_id, @plank).select(&:is_warmup)
  end
end

# The bug the workaround caused, pinned so it cannot come back: three weeks of a plank,
# lifted exactly as written each time.
describe 'an unloaded lift across a block' do
  include UnloadedLifts

  it 'still weighs nothing in week three' do
    account_id = an_account
    plank = a_movement(account_id)
    program = a_block(account_id, weeks: 3)
    prescribed = (1..3).map do |number|
      a_lift(program, number, plank, progression: 'unloaded', top_weight: nil, is_barbell: false)
      Tectonic::ProgramGenerator.new(program).generate(number)
      fresh = sets_for(account_id, plank).reject(&:is_completed)
      fresh.each { |set| set.update(is_completed: true) }
      fresh.map(&:weight).uniq
    end

    assert_equal [[nil], [nil], [nil]], prescribed
  end
end

describe 'writing an unloaded lift through the shared writer' do
  include UnloadedLifts

  before do
    @account_id = an_account
    @context = Tectonic::MCP::RequestContext.new(account_id: @account_id, email: nil, scopes: [],
                                                 application_id: nil)
    @program = a_block(@account_id, weeks: 1)
    week = @program.program_weeks.first
    @day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
  end

  def write(**attributes)
    Tectonic::MCP::Tools::ProgramWriter.lift(@context, @day,
                                             { exercise: a_movement(@account_id).name, sets: 3,
                                               reps: 10 }.merge(attributes))
  end

  it 'accepts a lift with neither a weight nor a percentage' do
    assert_equal 'unloaded', write(is_unloaded: true).progression
  end

  # Whatever the movement's own barbell flag says, unloaded work is not on a bar -- and
  # that is what keeps a 45 lb ramp off a weightless lift.
  it 'is never on a bar' do
    lift = Tectonic::MCP::Tools::ProgramWriter.lift(
      @context, @day, { exercise: a_movement(@account_id, barbell: true).name, sets: 3, reps: 10,
                        is_unloaded: true }
    )

    refute lift.is_barbell
  end
end

describe 'a lift the writer will not accept' do
  include UnloadedLifts

  before do
    @account_id = an_account
    @context = Tectonic::MCP::RequestContext.new(account_id: @account_id, email: nil, scopes: [],
                                                 application_id: nil)
    week = a_block(@account_id, weeks: 1).program_weeks.first
    @day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
  end

  def write(**attributes)
    Tectonic::MCP::Tools::ProgramWriter.lift(@context, @day,
                                             { exercise: a_movement(@account_id).name, sets: 3,
                                               reps: 10 }.merge(attributes))
  end

  # The workaround this replaces, refused by name so a model is told what to write instead.
  it 'refuses a lift written at zero pounds' do
    error = assert_raises(Tectonic::MCP::Tool::Refusal) { write(top_weight: 0) }

    assert_includes error.message, 'is_unloaded'
  end

  it 'refuses a lift that is both unloaded and priced' do
    assert_raises(Tectonic::MCP::Tool::Refusal) { write(is_unloaded: true, top_weight: 95) }
    assert_raises(Tectonic::MCP::Tool::Refusal) { write(is_unloaded: true, percent_of_max: 70) }
  end

  it 'still refuses a lift that says nothing about its load at all' do
    error = assert_raises(Tectonic::MCP::Tool::Refusal) { write }

    assert_includes error.message, 'is_unloaded'
  end
end

# The database holds the invariant for anything that writes to it, not only for the two
# code paths that go through the writer.
describe 'the unloaded constraint' do
  include UnloadedLifts

  it 'refuses a priced unloaded row written straight to the table' do
    account_id = an_account
    program = a_block(account_id, weeks: 1)
    week = program.program_weeks.first
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)

    assert_raises(Sequel::CheckConstraintViolation) do
      Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: a_movement(account_id).id,
                                   position: 0, sets: 3, reps: 10, top_weight: 95,
                                   progression: 'unloaded', is_main: false, is_barbell: false)
    end
  end
end

