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

# Once a lifter has answered a prescription, that row is what happened rather than a plan to
# be revised. Rewriting it would delete training.
#
# **The protected unit is the set, not the day it sits in.** #407. This used to stop the
# moment one set in the session was ticked off, and the two assertions below used to pin that
# -- the session unchanged at [145, 150, 155], and "left alone". Both were describing the bug:
# on 2026-09-14 the squats were done and the hip thrusts were not, so a hip thrust removed
# from the programme stayed in the session as four untouched planned sets, read as current
# programming, and had to be found by hand. It compounds across a block, because every
# partially-trained session keeps whatever the programme used to say for the rest of it.
describe 'editing a lift whose session has been part lifted' do
  include Rack::Test::Methods
  include SessionRefreshing

  before do
    @token = mint(scopes: %w[read write])
    _program, @day, @lift = a_block(@token.account_id)
    workout = Tectonic::Workout.where(program_day_id: @day.id).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).first.update(is_completed: true)
  end

  it 'leaves the lifted set exactly as it was and rewrites the rest' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_equal [145, 220, 225], working_weights(@day)
  end

  # The set already done covers the row the plan would have written in its place, so the
  # session still holds three working sets rather than four.
  it 'writes the rest of the plan rather than a second copy of it' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })

    assert_equal 3, working_weights(@day).length
  end

  # A model that is not told how much was rewritten and how much was kept cannot tell the
  # lifter what their session now is.
  it 'says what it rewrote and what it kept' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift.id, top_weight: 225 })
    said = tool_result['content'].first['text']

    assert_equal 225, @lift.refresh.top_weight
    assert_includes said, '1 left because it was completed'
  end
end

# The one case where "left alone" is still the whole answer: nothing in the session is
# unfinished, so there is nothing to rewrite around.
#
# It is also what holds the other side of #441 down. That narrowed :lifted to refuse a session
# something had been deleted from, and a narrowing that went too far would leave nothing
# saying "left alone" at all -- so the assertion below is now load-bearing in both directions
# rather than only describing the happy case.
describe 'editing a lift whose session is entirely lifted' do
  include Rack::Test::Methods
  include SessionRefreshing

  before do
    @token = mint(scopes: %w[read write])
    _program, @day, @lift = a_block(@token.account_id)
    workout = Tectonic::Workout.where(program_day_id: @day.id).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).update(is_completed: true)
  end

  it 'leaves every set as it was' do
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

# The case the issue was filed from: a movement taken out of the programme, in a session
# where something else had already been lifted.
describe 'removing a lift from a session that has other work in it' do
  include Rack::Test::Methods
  include SessionRefreshing

  it 'takes the removed movement out rather than leaving it as current programming' do
    token = mint(scopes: %w[read write])
    _program, day, lift = a_block(token.account_id)
    workout = Tectonic::Workout.where(program_day_id: day.id).first
    other = Tectonic::Exercise.create(account_id: token.account_id, name: "Hip Thrust #{SecureRandom.hex(4)}")
    # A lifted set of a different movement, which is what used to skip the whole day.
    Tectonic::WorkoutSet.insert(workout_id: workout.id, exercise_id: other.id, weight: 95, reps: 8,
                                is_warmup: false, is_completed: true, completed_at: Time.now,
                                is_barbell: true)
    call_tool('delete_program_lift', raw: token.raw, arguments: { program_lift_id: lift.id })
    left = Tectonic::WorkoutSet.where(workout_id: workout.id).all

    assert_equal 1, left.length, 'only the lifted set should remain'
    assert_equal other.id, left.first.exercise_id
  end
end

# What it *says* about having done that, which is the half #441 was still getting wrong after
# #407 fixed the half above.
#
# `written` and `kept` describe what the plan put into the session and neither can see what
# came out, so a refresh that deleted seven planned sets and had nothing to write back scored
# zero written, one kept -- indistinguishable from a session nobody touched, and reported as
# "left alone" while seven sets were being deleted from it. A lifter told that goes looking
# for the movement in the session it was just taken out of, which is how this was found.
describe 'what it says about a session it has just emptied' do
  include Rack::Test::Methods
  include SessionRefreshing

  it 'does not report a gutted session as one that was left alone' do
    token = mint(scopes: %w[read write])
    _program, day, lift = a_block(token.account_id)
    workout = Tectonic::Workout.where(program_day_id: day.id).first
    other = Tectonic::Exercise.create(account_id: token.account_id, name: "Hip Thrust #{SecureRandom.hex(4)}")
    Tectonic::WorkoutSet.insert(workout_id: workout.id, exercise_id: other.id, weight: 95, reps: 8,
                                is_warmup: false, is_completed: true, completed_at: Time.now,
                                is_barbell: true)

    call_tool('delete_program_lift', raw: token.raw, arguments: { program_lift_id: lift.id })
    said = tool_result['content'].first['text']

    refute_includes said, 'left alone'
    assert_includes said, '7 planned sets taken out'
    assert_includes said, '1 set already lifted stays as it is'
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

