# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# Editing a prescription used to leave the session it had already produced exactly as it
# was. The only way to apply a change was to know generation had happened and then fix
# every set by hand -- and nothing said that it had. An untrained session is only ever a
# copy of the plan, so it is rewritten; one with lifted work in it is a record of what
# happened and is left alone.
module SessionRefreshing
  def a_block(account_id, weight: 155)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: 'Block', start_date: Date.today, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
    lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                        sets: 3, reps: 5, top_weight: weight, progression: 'linear',
                                        is_main: true, is_barbell: true)
    Tectonic::ProgramGenerator.new(program).generate(1)
    [program, day, lift]
  end

  def working_weights(day)
    workout = Tectonic::Workout.where(program_day_id: day.id).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).order(:id).map(&:weight)
  end
end

describe 'editing a lift whose session is already generated' do
  include Rack::Test::Methods
  include SessionRefreshing

  before do
    @token = mint(scopes: %w[read write])
    _program, @day, @lift = a_block(@token.account_id)
  end

  it 'rewrites the planned session to match' do
    assert_equal [145, 150, 155], working_weights(@day)

    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_equal [210, 220, 225], working_weights(@day)
  end

  it 'says so, so a model does not have to guess whether the edit landed' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_includes tool_result['content'].first['text'], 'rewritten to match'
  end
end

# Once a lifter has answered a prescription, those rows are what happened rather than a
# plan to be revised. Rewriting them would delete training.
describe 'editing a lift whose session has been lifted' do
  include Rack::Test::Methods
  include SessionRefreshing

  before do
    @token = mint(scopes: %w[read write])
    _program, @day, @lift = a_block(@token.account_id)
    workout = Tectonic::Workout.where(program_day_id: @day.id).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).first.update(is_completed: true)
  end

  it 'leaves the session alone' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_equal [145, 150, 155], working_weights(@day)
  end

  it 'still makes the edit to the plan, and says the session was left' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_equal 225, @lift.refresh.top_weight
    assert_includes tool_result['content'].first['text'], 'left alone'
  end
end

describe 'adding and removing a lift after generation' do
  include Rack::Test::Methods
  include SessionRefreshing

  before do
    @token = mint(scopes: %w[read write])
    _program, @day, @lift = a_block(@token.account_id)
  end

  def set_count
    Tectonic::WorkoutSet.where(workout_id: Tectonic::Workout.where(program_day_id: @day.id).select(:id)).count
  end

  it 'puts a newly added lift into the session' do
    before_add = set_count
    call_tool('add_program_lift', raw: @token.raw,
                                  arguments: { program_day_id: @day.id, exercise: 'Bench Press',
                                               sets: 3, reps: 5, top_weight: 135 })

    assert_operator set_count, :>, before_add
  end

  it 'takes a removed lift out of the session' do
    call_tool('delete_program_lift', raw: @token.raw, arguments: { program_lift_id: @lift.id })

    assert_equal 0, set_count
  end
end

# A day moved to another weekday used to leave its session behind on the old date, where
# nothing could match it again -- so regenerating wrote a second one.
describe 'a day moved to another weekday' do
  include Rack::Test::Methods
  include SessionRefreshing

  it 'moves its session rather than stranding it' do
    token = mint(scopes: %w[read write])
    program, day, = a_block(token.account_id)
    moved = (day.weekday + 2) % 7
    day.update(weekday: moved)

    Tectonic::ProgramGenerator.new(program).refresh(day)
    Tectonic::ProgramGenerator.new(program).generate(1)

    workouts = Tectonic::Workout.where(program_day_id: day.id).all

    assert_equal 1, workouts.length
    assert_equal moved, workouts.first.date.wday
  end
end

