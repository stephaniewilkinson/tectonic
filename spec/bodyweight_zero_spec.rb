# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/progression'
require 'securerandom'

# A weight of zero is a way of saying bodyweight, and it is stored as none. #321.
#
# Single-Leg Hip Thrust rows read `0 lb × 10` -- a load nobody is being asked to lift, on
# the row a lifter reads at arm's length. Two halves to it, and the second is the real one:
# **zero is truthy in Ruby**, so every guard written as `if set[:weight]` took the weighted
# branch; and a zero should not have been stored at all, which is what 008 concluded for the
# prescription side in words this borrows.
module BodyweightZero
  def a_session_with(account_id, **columns)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    set_id = DB[:sets].insert(workout_id:, exercise_id:, is_warmup: false, is_completed: false, **columns)
    [workout_id, set_id]
  end

  def screen(workout_id)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  def rating_buttons(body)
    body.scan(/<button[^>]*name="rpe"[^>]*>\s*(\d+)/).flatten
  end
end

# The guard is `positive?` rather than truthiness, so a zero arriving from anywhere reads as
# the absence it means -- belt to the braces of storing none in the first place.
describe 'a set whose weight is stored as zero' do
  include Rack::Test::Methods
  include RouteOwnership
  include BodyweightZero

  before do
    @workout_id, = a_session_with(login, weight: 0, reps: 10)
    @body = screen(@workout_id)
  end

  it 'reads as a rep count rather than as a load' do
    assert_includes @body, '10 reps'
    refute_includes @body, '0 lb'
  end

  # #278 decided the screen does not ask for a rating on work carrying no load: the scale is
  # five 48px buttons, and the answer moves nothing Progression can step.
  it 'is not asked for a rating it has no load to rate' do
    assert_empty rating_buttons(@body)
  end
end

# planned_weight takes the same guard. The two sit one line apart on a changed set, and a
# zero on one of them would print "planned 0 × 5" over a row that says "10 reps".
describe 'a prescription stored as zero' do
  include Rack::Test::Methods
  include RouteOwnership
  include BodyweightZero

  it 'does not draw pounds it does not have' do
    workout_id, = a_session_with(login, weight: 0, reps: 10, planned_weight: 0, planned_reps: 10)

    refute_includes screen(workout_id), '0 lb'
  end
end

# The write path that produced every zero in the table: weight was required and
# Bounds::WEIGHT starts at zero, so a zero was the only thing a caller could send for a plank.
describe 'logging work that carries no load' do
  include Rack::Test::Methods
  include BodyweightZero

  before { @minted = mint(scopes: %w[read write]) }

  def logged = Tectonic::WorkoutSet[tool_result.dig('structuredContent', 'id')]

  it 'stores no weight when a zero is sent' do
    call_tool('create_set', raw: @minted.raw,
                            arguments: { exercise: "Plank #{SecureRandom.hex(4)}", weight: 0, reps: 10 })

    assert_nil logged.weight
  end

  # Optional since #321, so a caller with nothing to say about load can say nothing.
  it 'stores no weight when none is sent at all' do
    call_tool('create_set', raw: @minted.raw,
                            arguments: { exercise: "Plank #{SecureRandom.hex(4)}", reps: 10 })

    assert_nil logged.weight
  end

  # Read rather than refused: a model sending 0 for a plank is sending an unambiguous
  # message, and refusing it to make the model resend is the app arguing rather than
  # recording -- the wrong side of the line #263 drew.
  it 'confirms it in reps rather than as a bare x10' do
    call_tool('create_set', raw: @minted.raw,
                            arguments: { exercise: "Plank #{SecureRandom.hex(4)}", weight: 0, reps: 10 })

    assert_includes tool_result.dig('content', 0, 'text'), 'Logged 10 reps'
  end

  it 'still stores a real load as itself' do
    call_tool('create_set', raw: @minted.raw,
                            arguments: { exercise: "Squat #{SecureRandom.hex(4)}", weight: 225, reps: 5 })

    assert_equal 225, logged.weight.to_i
    assert_includes tool_result.dig('content', 0, 'text'), 'Logged 225x5'
  end
end

describe 'correcting a set to bodyweight' do
  include Rack::Test::Methods
  include BodyweightZero

  before { @minted = mint(scopes: %w[read write]) }

  it 'takes the load off when a zero is sent' do
    _, set_id = a_session_with(@minted.account_id, weight: 45, reps: 10)

    call_tool('update_set', raw: @minted.raw, arguments: { set_id:, weight: 0 })

    assert_nil Tectonic::WorkoutSet[set_id].weight
  end

  # `key?` rather than truthiness, so a call that never mentions weight still leaves it.
  it 'leaves a load alone when the call does not mention it' do
    _, set_id = a_session_with(@minted.account_id, weight: 45, reps: 10)

    call_tool('update_set', raw: @minted.raw, arguments: { set_id:, reps: 12 })

    assert_equal 45, Tectonic::WorkoutSet[set_id].weight.to_i
  end
end

describe 'reading unloaded work back over MCP' do
  include Rack::Test::Methods
  include BodyweightZero

  it 'says the reps rather than a bare x10' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_session_with(minted.account_id, weight: nil, reps: 10)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), '10 reps'
    refute_includes tool_result.dig('content', 0, 'text'), 'x10'
  end

  it 'still prints a loaded set as weight by reps' do
    minted = mint(scopes: %w[read write])
    workout_id, = a_session_with(minted.account_id, weight: 225, reps: 5)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), '225x5'
  end
end

# A generated set corrected to bodyweight leaves a nil weight beside a planned one, and
# Progression compares the two raw -- so `nil >= 225` would raise on the progression of a
# whole block, which is a poor way to learn about one set.
describe 'whether an unloaded set met a prescribed load' do
  it 'answers no rather than raising' do
    set = { is_completed: true, weight: nil, reps: 5, planned_weight: 225, planned_reps: 5 }

    refute Tectonic::Progression.met?(set)
  end

  it 'still answers yes for a prescription with no load to meet' do
    set = { is_completed: true, weight: nil, reps: 10, planned_weight: nil, planned_reps: 10 }

    assert Tectonic::Progression.met?(set)
  end
end

