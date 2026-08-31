# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/volume'
require 'securerandom'

# A per-side set says so when it is read back. #306.
#
# The column has been on these rows since 009 and Volume has doubled a per-side count since
# #279, so the app's volume figures were already right -- while the MCP read tools printed
# `40x8` about sixteen reps of work and carried no flag to say otherwise. Two numbers from
# one app differing by exactly 2x, with nothing explaining which was which, which is worse
# than either being wrong on its own.
module PerSideReads
  def a_split_squat(account_id, reps: 8)
    exercise = Tectonic::Exercise.create(name: "Split Squat #{SecureRandom.hex(4)}", account_id:,
                                         default_is_per_side: true)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 40, reps:,
                     is_warmup: false, is_completed: true, is_barbell: false, is_per_side: true)
    [workout_id, exercise]
  end

  def a_bilateral_set(account_id)
    exercise = Tectonic::Exercise.create(name: "Bench #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                     is_warmup: false, is_completed: true, is_barbell: true)
    [workout_id, exercise]
  end
end

describe 'get_workout on a per-side set' do
  include Rack::Test::Methods
  include PerSideReads

  it 'says per side in the prose' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_split_squat(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), '40x8 per side'
  end

  it 'carries the flag in the payload' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_split_squat(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert tool_result.dig('structuredContent', 'sets', 0, 'is_per_side')
  end

  # The ordinary set has to keep reading the way it always did, since almost every set is
  # one and a stray "per side" on a bench press would be worse than the silence it replaces.
  it 'says nothing extra about a bilateral set' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_bilateral_set(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    refute_includes tool_result.dig('content', 0, 'text'), 'per side'
    refute tool_result.dig('structuredContent', 'sets', 0, 'is_per_side')
  end
end

# The disagreement this closes, asserted as the two numbers agreeing rather than as either
# one being right: what an assistant reads and what the volume page reports are now the same
# claim about the same set.
describe 'what a reader sees against what Volume counts' do
  include Rack::Test::Methods
  include PerSideReads

  it 'no longer differs by a factor of two with nothing to explain it' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise = a_split_squat(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })
    read = tool_result.dig('structuredContent', 'sets', 0)
    counted = Tectonic::Volume.weekly(minted.account_id, exercise_id: exercise.id, weeks: 1)
                              .sum { |row| row[:reps] }

    assert_equal 8, read.fetch('reps')
    assert read.fetch('is_per_side'), 'the reader has to be told, or 8 is the whole story'
    assert_equal 16, counted, 'Volume has counted this at sixteen since #279'
  end
end

# exercise_history reads through the same presenter, so it gets this without knowing about
# it -- which is the point of there being one presenter.
describe 'exercise_history on a per-side movement' do
  include Rack::Test::Methods
  include PerSideReads

  it 'carries the flag on every set it returns' do
    minted = mint(scopes: %w[read write])
    _workout_id, exercise = a_split_squat(minted.account_id)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert tool_result.dig('structuredContent', 'sets', 0, 'is_per_side')
  end
end

