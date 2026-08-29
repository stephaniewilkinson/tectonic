# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative 'mcp_program_tools_spec' # and its block_arguments/write_block; idempotent
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# The three tools #260 and #261 found missing: nothing could change a block's own
# settings, and nothing could remove a block or a session.
#
# Their absence compounded. With no update_program, the way to change is_ascending was to
# rebuild the block -- and with no delete_program, rebuilding left the abandoned one in
# every list_programs for as long as the account existed. The audit had one of those,
# `zz-probe`, still sitting there.
module Lifecycle
  def prose
    tool_result.dig('content', 0, 'text')
  end

  def payload
    tool_result['structuredContent']
  end

  def session_with(account_id, completed: 0, sets: 3)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    sets.times do |index|
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 155,
                                  reps: 5, is_warmup: false, is_completed: index < completed)
    end
    workout
  end
end

describe 'update_program' do
  include Rack::Test::Methods
  include Lifecycle

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
  end

  # The two that shape generation, and the reason this tool matters more than the other
  # three fields: they could only be changed by editing every generated set one at a time,
  # which leaves the ungenerated weeks to come out the old way.
  it 'changes how the block lays its sets out' do
    call_tool('update_program', raw: @token.raw,
                                arguments: { program_id: @program['id'], is_ascending: false, preferred_reps: 5 })

    refute payload['is_ascending']
    assert_equal 5, payload['preferred_reps']
  end

  it 'changes the block name, number and notes' do
    call_tool('update_program', raw: @token.raw,
                                arguments: { program_id: @program['id'], name: 'Re-entry', block: 2,
                                             notes: 'Coming back after six weeks off.' })

    assert_equal 'Re-entry', payload['name']
    assert_equal 2, payload['block']
  end

  it 'moves the block, and the dates its weeks fall on move with it' do
    call_tool('update_program', raw: @token.raw,
                                arguments: { program_id: @program['id'], start_date: '2027-02-01' })

    assert_equal '2027-02-01', payload['start_date']
  end
end

# A block setting changes how every set in every generated week was laid out, so unlike
# update_program_lift this does not rewrite them -- somebody may be halfway through
# today's session. Said out loud rather than done silently, so a model can offer to
# regenerate rather than a lifter finding today's work rearranged under them.
describe 'what update_program says about weeks already generated' do
  include Rack::Test::Methods
  include Lifecycle

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
  end

  it 'says they keep the sets they were written with' do
    call_tool('update_program', raw: @token.raw, arguments: { program_id: @program['id'], is_ascending: false })

    assert_includes prose, 'regenerate a week'
  end

  it 'says nothing when the edit does not affect generation' do
    call_tool('update_program', raw: @token.raw, arguments: { program_id: @program['id'], notes: 'A note.' })

    refute_includes prose, 'regenerate a week'
  end
end

describe 'update_program at the edges' do
  include Rack::Test::Methods
  include Lifecycle

  before { @token = mint(scopes: %w[read write]) }

  # name is NOT NULL, so a blank one would reach the constraint as a 500 and read as the
  # tool being broken rather than as the refusal it is.
  it 'refuses a blank name rather than letting the constraint answer' do
    program = write_block(@token.raw)
    call_tool('update_program', raw: @token.raw, arguments: { program_id: program['id'], name: '  ' })

    assert tool_result['isError']
    assert_includes prose, 'needs a name'
    assert_equal program['name'], Tectonic::Program[program['id']].name
  end

  it 'refuses another account\'s block' do
    other = write_block(mint(scopes: %w[read write]).raw)
    call_tool('update_program', raw: @token.raw, arguments: { program_id: other['id'], name: 'Mine now' })

    assert tool_result['isError']
    assert_equal other['name'], Tectonic::Program[other['id']].name
  end
end

describe 'delete_program' do
  include Rack::Test::Methods
  include Lifecycle

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
  end

  # The zz-probe case: a block written while probing the API, never generated, permanent.
  it 'removes a block nobody has generated, with no ceremony' do
    call_tool('delete_program', raw: @token.raw, arguments: { program_id: @program['id'] })

    refute tool_result['isError'], prose
    assert_nil Tectonic::Program[@program['id']]
    assert_includes prose, 'generated no sessions'
  end

  it 'takes the weeks, days and lifts with it' do
    week = @program['weeks'].first
    day = week['days'].first
    call_tool('delete_program', raw: @token.raw, arguments: { program_id: @program['id'] })

    assert_nil Tectonic::ProgramWeek[week['id']]
    assert_nil Tectonic::ProgramDay[day['id']]
    assert_empty Tectonic::ProgramLift.where(id: day['lifts'].map { |lift| lift['id'] }).all
  end
end

describe 'delete_program on a block that is not yours' do
  include Rack::Test::Methods
  include Lifecycle

  it 'refuses, and leaves it standing' do
    other = write_block(mint(scopes: %w[read write]).raw)
    call_tool('delete_program', raw: mint(scopes: %w[read write]).raw, arguments: { program_id: other['id'] })

    assert tool_result['isError']
    refute_nil Tectonic::Program[other['id']]
  end
end

# The decision worth pinning, because the other reading is defensible and wrong: a
# generated workout is a day somebody trained, and the block is only where its numbers
# came from. Deleting a block in March must not delete February's training.
describe 'deleting a block that has already written sessions' do
  include Rack::Test::Methods
  include Lifecycle

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 1 })
    @day = @program['weeks'].first['days'].first
    @workout = Tectonic::Workout.where(program_day_id: @day['id']).first
  end

  it 'refuses without confirm, saying what would be lost' do
    call_tool('delete_program', raw: @token.raw, arguments: { program_id: @program['id'] })

    assert tool_result['isError']
    assert_includes prose, 'generated 1 session'
    refute_nil Tectonic::Program[@program['id']]
  end

  it 'keeps the sessions as hand-logged workouts when confirmed, and says how many' do
    call_tool('delete_program', raw: @token.raw, arguments: { program_id: @program['id'], confirm: true })

    refute tool_result['isError'], prose
    assert_nil Tectonic::Program[@program['id']]
    assert_nil @workout.refresh.program_day_id
    refute_empty Tectonic::WorkoutSet.where(workout_id: @workout.id).all
    assert_equal 1, payload['orphaned_workouts']
    assert_includes prose, 'kept as hand-logged workouts'
  end
end

describe 'delete_workout' do
  include Rack::Test::Methods
  include Lifecycle

  before { @token = mint(scopes: %w[read write]) }

  # The two empty workouts #261 found, opened and never logged, inflating every count.
  it 'removes a session nothing was lifted in' do
    workout = session_with(@token.account_id, sets: 0)
    call_tool('delete_workout', raw: @token.raw, arguments: { workout_id: workout.id })

    refute tool_result['isError'], prose
    assert_nil Tectonic::Workout[workout.id]
  end

  # sets.workout_id is NOT NULL with no cascade, so the parent cannot go while a child
  # points at it. Asserted because getting the order wrong raises rather than leaking.
  it 'takes its sets with it' do
    workout = session_with(@token.account_id, sets: 3)
    call_tool('delete_workout', raw: @token.raw, arguments: { workout_id: workout.id })

    refute tool_result['isError'], prose
    assert_empty Tectonic::WorkoutSet.where(workout_id: workout.id).all
  end

  it 'hands back what it removed, so the wrong one can be written again' do
    workout = session_with(@token.account_id, sets: 2)
    call_tool('delete_workout', raw: @token.raw, arguments: { workout_id: workout.id })

    assert_equal 2, payload['removed']['sets'].length
    assert_equal 155, payload['removed']['sets'].first['weight']
  end
end

describe 'delete_workout on a session that is not yours' do
  include Rack::Test::Methods
  include Lifecycle

  it 'refuses, and leaves it standing' do
    theirs = session_with(mint(scopes: %w[read write]).account_id)
    call_tool('delete_workout', raw: mint(scopes: %w[read write]).raw, arguments: { workout_id: theirs.id })

    assert tool_result['isError']
    refute_nil Tectonic::Workout[theirs.id]
  end
end

# Same rule delete_set follows: work that was lifted is training history, and an assistant
# tidying up after itself has no business removing it without being asked.
describe 'deleting a session that was trained' do
  include Rack::Test::Methods
  include Lifecycle

  before do
    @token = mint(scopes: %w[read write])
    @workout = session_with(@token.account_id, sets: 3, completed: 2)
  end

  it 'refuses without confirm, saying how much was lifted' do
    call_tool('delete_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert tool_result['isError']
    assert_includes prose, '2 completed set(s)'
    refute_nil Tectonic::Workout[@workout.id]
  end

  it 'removes it when confirmed' do
    call_tool('delete_workout', raw: @token.raw, arguments: { workout_id: @workout.id, confirm: true })

    refute tool_result['isError'], prose
    assert_nil Tectonic::Workout[@workout.id]
  end
end

