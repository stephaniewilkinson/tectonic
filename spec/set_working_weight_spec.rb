# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'

# One weight onto every working set of one movement. #312.
#
# update_set takes a single set_id, so switching a six-set lift from ascending to flat is six
# calls -- six round trips in which a model can lose its place and leave half a lift at the
# old weight. What is asserted here is mostly what it must *not* touch, because a bulk write
# that reached too far would delete training to save typing.
module WorkingWeight
  # A lift part-way through: a warmup, two working sets already done, three still to do,
  # each carrying the prescription the generator would have written.
  def a_part_trained_lift(account_id, top: 225)
    exercise = Tectonic::Exercise.create(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    common = { workout_id:, exercise_id: exercise.id, is_barbell: true, reps: 5, planned_reps: 5 }
    DB[:sets].insert(**common, weight: 135, planned_weight: 135, is_warmup: true, is_completed: false)
    2.times do
      DB[:sets].insert(**common, weight: top, planned_weight: top, is_warmup: false,
                                 is_completed: true, completed_at: Time.now)
    end
    3.times { DB[:sets].insert(**common, weight: top, planned_weight: top, is_warmup: false, is_completed: false) }
    [workout_id, exercise]
  end

  def working(workout_id) = Tectonic::WorkoutSet.where(workout_id:, is_warmup: false).order(:id).all

  def warmup(workout_id) = Tectonic::WorkoutSet.where(workout_id:, is_warmup: true).first
end

describe 'putting one weight on the sets that are left' do
  include Rack::Test::Methods
  include WorkingWeight

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id, @exercise = a_part_trained_lift(@minted.account_id)
    call_tool('set_working_weight', raw: @minted.raw,
                                    arguments: { workout_id: @workout_id, exercise: @exercise.name, weight: 205 })
  end

  it 'moves the ones still to do' do
    assert_equal([205, 205, 205], working(@workout_id).reject(&:is_completed).map { |s| s.weight.to_i })
  end

  # Completed sets are a record of what happened. A bulk edit that rewrote them would delete
  # training to save typing, which is the one thing this must never do.
  it 'leaves the ones already done exactly as they were' do
    assert_equal([225, 225], working(@workout_id).select(&:is_completed).map { |s| s.weight.to_i })
  end

  # A ramp is computed from the top set rather than chosen, so writing 205 across it would
  # flatten it into six working sets.
  it 'leaves the warmup alone' do
    assert_equal 135, warmup(@workout_id).weight.to_i
  end

  # The one that matters most. planned_weight untouched is what keeps "asked for 225, did
  # 205" readable afterwards -- the same rule complete_set follows.
  it 'leaves the prescription alone, so the change stays legible' do
    assert_equal([225] * 5, working(@workout_id).map { |s| s.planned_weight.to_i })
  end
end

# A caller that asked for six and moved four needs to be told, rather than left to assume the
# whole lift changed.
describe 'what a bulk write reports' do
  include Rack::Test::Methods
  include WorkingWeight

  it 'says how many moved and how many were left' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise = a_part_trained_lift(minted.account_id)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: exercise.name, weight: 205 })

    assert_equal 3, tool_result.dig('structuredContent', 'moved')
    assert_equal 2, tool_result.dig('structuredContent', 'left')
    assert_includes tool_result.dig('content', 0, 'text'), '3 working set(s) set to 205'
    assert_includes tool_result.dig('content', 0, 'text'), '2 already completed and left alone'
  end
end

# "0 sets" and "0 sets, 4 already done" are different answers, and only one of them means the
# caller named the wrong movement.
describe 'a lift with nothing left to change' do
  include Rack::Test::Methods
  include WorkingWeight

  it 'says nothing moved and why' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise = a_part_trained_lift(minted.account_id)
    Tectonic::WorkoutSet.where(workout_id:).update(is_completed: true, completed_at: Time.now)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: exercise.name, weight: 205 })

    assert_equal 0, tool_result.dig('structuredContent', 'moved')
    assert_includes tool_result.dig('content', 0, 'text'), 'already completed and left alone'
  end
end

describe 'naming something that is not there' do
  include Rack::Test::Methods
  include WorkingWeight

  # Refused rather than resolved-and-created: creating the movement to write nothing to it
  # would leave a row behind and report success.
  it 'refuses a movement this account does not have' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_part_trained_lift(minted.account_id)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: "Nope #{SecureRandom.hex(4)}",
                                                 weight: 205 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No exercise named'
  end

  it 'refuses a workout belonging to somebody else' do
    minted = mint(scopes: %w[read write])
    stranger = mint(scopes: %w[read write])
    workout_id, exercise = a_part_trained_lift(stranger.account_id)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: exercise.name, weight: 205 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No workout with id'
  end
end

# The same bound every other load written through MCP is checked against, so a refusal reads
# identically wherever it came from.
describe 'a weight nobody lifts' do
  include Rack::Test::Methods
  include WorkingWeight

  it 'is refused by naming the bound' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise = a_part_trained_lift(minted.account_id)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: exercise.name, weight: 9999 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'Weight 9999 is out of range'
  end
end

# One movement, not the whole session: a day usually holds several lifts and only one of them
# is being flattened.
describe 'a session holding more than one movement' do
  include Rack::Test::Methods
  include WorkingWeight

  it 'touches only the movement it was given' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise = a_part_trained_lift(minted.account_id)
    other = Tectonic::Exercise.create(name: "Bench #{SecureRandom.hex(4)}", account_id: minted.account_id)
    DB[:sets].insert(workout_id:, exercise_id: other.id, weight: 155, reps: 5,
                     is_warmup: false, is_completed: false, is_barbell: true)

    call_tool('set_working_weight', raw: minted.raw,
                                    arguments: { workout_id:, exercise: exercise.name, weight: 205 })

    assert_equal 155, Tectonic::WorkoutSet.where(workout_id:, exercise_id: other.id).first.weight.to_i
  end
end

