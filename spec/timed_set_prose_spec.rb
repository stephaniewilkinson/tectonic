# frozen_string_literal: true

# A timed set has no reps, and the sentences an assistant reads about one used to say so by
# leaving a hole: create_set confirmed a 30-second cat-cow as "Logged  reps of Cat-Cow", and
# get_workout read it back the same way. The session screen has said "30s" all along; these
# say what it says.

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require 'securerandom'

module TimedSetProse
  # A fresh movement and one 30-second set of it; returns the movement's name and the reply.
  def log_timed(minted, stem, **extra)
    name = "#{stem} #{SecureRandom.hex(4)}"
    call_tool('create_exercise', raw: minted.raw, arguments: { name:, new_exercise: true })
    call_tool('create_set', raw: minted.raw,
                            arguments: { exercise: name, measure: 'time', duration_seconds: 30, **extra })
    [name, tool_result.dig('content', 0, 'text')]
  end
end

describe 'the prose about a timed set' do
  include Rack::Test::Methods
  include TimedSetProse

  it 'confirms the seconds when a timed set is logged' do
    name, text = log_timed(mint(scopes: %w[read write]), 'Cat-Cow')

    assert_includes text, "Logged 30s of #{name}"
    refute_includes text, ' reps'
  end

  it 'keeps the load on a loaded timed set' do
    name, text = log_timed(mint(scopes: %w[read write]), 'Farmer Carry', weight: 50)

    assert_includes text, "Logged 50x30s of #{name}"
  end

  it 'reads the seconds back in get_workout, words and payload' do
    minted = mint(scopes: %w[read write])
    name, = log_timed(minted, 'Deep Squat Hold')

    call_tool('get_workout', raw: minted.raw, arguments: {})

    assert_includes tool_result.dig('content', 0, 'text'), "#{name} 30s"
    assert_equal 30, tool_result.dig('structuredContent', 'sets', 0, 'duration_seconds')
  end
end

