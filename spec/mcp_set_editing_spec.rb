# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# A set as the generator writes one: prescribed, not yet lifted.
def written_set(account_id, weight: 155, is_completed: false)
  exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
  workout = Tectonic::Workout.create(account_id:, date: Date.today)
  Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight:, reps: 5,
                              planned_weight: weight, planned_reps: 5, is_warmup: false, is_completed:)
end

describe 'complete_set' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @set = written_set(@token.account_id)
  end

  it 'marks a written set as lifted' do
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: @set.id })
    assert tool_result['structuredContent']['is_completed']
    assert @set.refresh.is_completed
  end

  it 'records what was actually lifted and leaves the prescription alone' do
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 185, reps: 3, rpe: 9 })
    lifted = tool_result['structuredContent']
    assert_equal [185, 3, 9], lifted.values_at('weight', 'reps', 'rpe')
    assert_equal [155, 5], lifted.values_at('planned_weight', 'planned_reps')
    assert_includes tool_result.dig('content', 0, 'text'), 'weight 155 to 185'
  end

  it 'undoes a completion when told to' do
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: @set.id })
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: @set.id, completed: false })
    refute @set.refresh.is_completed
  end
end

describe 'complete_set bounds' do
  include Rack::Test::Methods

  it 'refuses a rating outside the scale, naming the bound' do
    token = mint(scopes: %w[read write])
    set = written_set(token.account_id)
    call_tool('complete_set', raw: token.raw, arguments: { set_id: set.id, rpe: 12 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'RPE 12 is out of range; use 1-10'
    refute set.refresh.is_completed
  end
end

describe 'update_set' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @set = written_set(@token.account_id)
  end

  it 'corrects the numbers and reports only what moved' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 165, reps: 5 })
    changed = tool_result['structuredContent']['changed']
    assert_equal({ 'from' => 155, 'to' => 165 }, changed['weight'])
    refute changed.key?('reps') # it was already five
  end

  it 'moves a set onto another movement, taking its plate math with it' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, exercise: 'Cable Fly' })
    assert_equal 'Cable Fly', tool_result['structuredContent']['exercise']
    refute @set.refresh.is_barbell
  end

  it 'refuses a weight outside the bounds with the same words create_set uses' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 99_999 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'out of range; use 0-2000 lb'
    assert_equal 155, @set.refresh.weight
  end
end

describe 'delete_set' do
  include Rack::Test::Methods

  before { @token = mint(scopes: %w[read write]) }

  it 'removes a set it should not have written, and says what it removed' do
    set = written_set(@token.account_id)
    call_tool('delete_set', raw: @token.raw, arguments: { set_id: set.id })
    assert_equal 155, tool_result['structuredContent']['removed']['weight']
    assert_nil Tectonic::WorkoutSet[set.id]
  end

  # Training that happened is not an assistant's to tidy away on its own initiative.
  it 'refuses to delete lifted work without an explicit confirmation' do
    set = written_set(@token.account_id, is_completed: true)
    call_tool('delete_set', raw: @token.raw, arguments: { set_id: set.id })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'confirm true'
    refute_nil Tectonic::WorkoutSet[set.id]

    call_tool('delete_set', raw: @token.raw, arguments: { set_id: set.id, confirm: true })
    assert_nil Tectonic::WorkoutSet[set.id]
  end
end

describe 'set editing isolation between accounts' do
  include Rack::Test::Methods

  before do
    @set = written_set(mint(scopes: ['write']).account_id)
    @stranger = mint(scopes: %w[read write]).raw
  end

  it "never completes, edits or deletes another account's set" do
    call_tool('complete_set', raw: @stranger, arguments: { set_id: @set.id })
    assert tool_result['isError']
    call_tool('update_set', raw: @stranger, arguments: { set_id: @set.id, weight: 999 })
    assert tool_result['isError']
    call_tool('delete_set', raw: @stranger, arguments: { set_id: @set.id })
    assert tool_result['isError']

    assert_equal [155, false], @set.refresh.values.values_at(:weight, :is_completed)
  end
end

describe 'the write kill switch' do
  include Rack::Test::Methods

  # Every one of these is a write tool, so the operator switch that stops writes has to
  # stop them too -- which it does structurally, from the base class, rather than each
  # tool remembering to ask.
  it 'refuses the editing tools while writes are off, and leaves reads working' do
    token = mint(scopes: %w[read write])
    set = written_set(token.account_id)
    ENV['MCP_WRITES_ENABLED'] = 'false'
    %w[complete_set update_set delete_set].each do |tool|
      call_tool(tool, raw: token.raw, arguments: { set_id: set.id })
      assert tool_result['isError'], "#{tool} should refuse while writes are disabled"
    end
    call_tool('get_workout', raw: token.raw, arguments: { workout_id: set.workout_id })
    refute tool_result['isError']
  ensure
    ENV.delete('MCP_WRITES_ENABLED')
  end
end

# #364: update_set rewrote a completed set without a word, and the loss it caused was real
# -- three sets of DB Overhead Tricep Extension performed at 14x20, 20x10 and 20x15 became
# Band Tricep Pushdown with the loads and reps discarded. delete_set has guarded exactly
# this since it was written; this is the same guard arriving on the tool that does the same
# damage.
describe 'update_set moving a lifted set onto another movement' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @set = written_set(@token.account_id, is_completed: true)
  end

  # No confirm on this one. A swap says a different movement was performed, so there is no
  # reading under which the recorded load and reps are still true.
  it 'refuses to move a lifted set onto a different movement' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, exercise: 'Band Tricep Pushdown' })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'a different set'
    assert_equal 155, Tectonic::Plates.numeric(@set.refresh.weight)
  end

  it 'points at delete and create rather than leaving the model stuck' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, exercise: 'Band Tricep Pushdown' })

    assert_includes tool_result.dig('content', 0, 'text'), "delete set #{@set.id}"
    assert_includes tool_result.dig('content', 0, 'text'), 'create the Band Tricep Pushdown set'
  end

  # The refusal is about a *different* movement. Re-sending the name the set already carries
  # is not a swap, and an assistant echoing back a row it just read should not be stopped.
  it 'allows naming the movement the set is already on' do
    call_tool('update_set', raw: @token.raw,
                            arguments: { set_id: @set.id, exercise: @set.exercise.name, rpe: 8 })

    refute tool_result['isError']
    assert_equal 8, @set.refresh.rpe
  end
end

# The other half of the guard: the numbers themselves, behind the same confirm delete_set
# uses rather than refused outright, because correcting a typo is legitimate.
describe 'update_set over the weight and reps of a lifted set' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @set = written_set(@token.account_id, is_completed: true)
  end

  it 'refuses a weight change without confirm, and writes nothing' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 225 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'rewrites training that happened'
    assert_equal 155, Tectonic::Plates.numeric(@set.refresh.weight)
  end

  it 'names both fields when both would move' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 225, reps: 3 })

    assert_includes tool_result.dig('content', 0, 'text'), 'weight and reps'
  end

  # Correcting a typo has to stay possible. That was never in doubt; the point of #364 is
  # that it should not happen silently.
  it 'allows the correction once confirmed' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 225, confirm: true })

    refute tool_result['isError']
    assert_equal 225, Tectonic::Plates.numeric(@set.refresh.weight)
  end
end

# What the guard deliberately lets through, which is as much a part of it as the refusals:
# a guard that stopped these would make rating a set a two-step call and turn every echoed
# row into an error.
describe 'update_set on a lifted set where nothing is being rewritten' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @set = written_set(@token.account_id, is_completed: true)
  end

  # Rating a set after lifting it is the ordinary way round, and it overwrites nothing that
  # was measured, so it never asks for confirmation.
  it 'leaves rating a completed set unguarded' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, rpe: 9 })

    refute tool_result['isError']
    assert_equal 9, @set.refresh.rpe
  end

  # Re-sending the value a row already holds moves nothing, so it is not an overwrite and
  # does not need confirming.
  it 'does not ask about a value that is already there' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 155, reps: 5 })

    refute tool_result['isError']
  end
end

# The guard is about completed sets only. A written-but-not-lifted set is a prescription,
# and correcting one is what this tool is for.
describe 'update_set on a set that has not been lifted' do
  include Rack::Test::Methods

  it 'changes weight and movement freely' do
    token = mint(scopes: %w[read write])
    set = written_set(token.account_id)
    call_tool('update_set', raw: token.raw,
                            arguments: { set_id: set.id, weight: 225, exercise: 'Front Squat' })

    refute tool_result['isError']
    assert_equal 225, Tectonic::Plates.numeric(set.refresh.weight)
    assert_equal 'Front Squat', set.refresh.exercise.name
  end
end

