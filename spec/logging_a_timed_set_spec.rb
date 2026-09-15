# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/measured'
require 'securerandom'
require 'date'

# Work counted in seconds can be logged as work counted in seconds. #471.
#
# `add_program_lift` and `create_program` have taken `measure: time` and `duration_seconds`
# since #211 gave sets a measure at all. `create_set` took neither and required reps, so the
# logging path still needed the encoding the prescription path had stopped needing:
#
#     create_set(exercise: "Bike Intervals", duration_seconds: 4020, is_completed: true)
#       -> Missing required arguments: reps
#
# A 1h 7m ride on 2026-09-14 went into the log as **67 reps** -- minutes in the rep column --
# because that was the only shape the tool would accept.
module TimedSets
  def a_timed_movement(account_id, name: 'Bike Intervals')
    Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: false)
  end

  def log(raw, **arguments)
    call_tool('create_set', raw:, arguments:)
  end

  def said = tool_result.dig('content', 0, 'text')

  def logged_set = Tectonic::WorkoutSet[tool_result['structuredContent']['id']]
end

describe 'logging the ride that could not be logged' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_timed_movement(@token.account_id)
  end

  # The reported call, verbatim, including the duration that prompted the issue.
  it 'takes a duration instead of reps' do
    log(@token.raw, exercise: @exercise.name, duration_seconds: 4020, is_completed: true)

    refute tool_result['isError'], said
    assert_equal 4020, logged_set.duration_seconds
    assert_nil logged_set.reps
  end

  # 4020 seconds is 1h 7m, and the bound used to stop at an hour -- described in its own
  # comment as covering "a walk or a bike interval", which this is the report that it did not.
  it 'allows a duration past the hour the bound used to stop at' do
    log(@token.raw, exercise: @exercise.name, duration_seconds: 4020)

    refute tool_result['isError'], said
  end

  # Still bounded. The cap is what catches a duration that is really a mistyped millisecond
  # count, which is the error it exists for.
  it 'still refuses a duration nobody trained' do
    log(@token.raw, exercise: @exercise.name, duration_seconds: 4_020_000)

    assert tool_result['isError']
  end
end

# Which of the two counts a set uses, inferred where the caller did not say. Inferring is what
# lets the ordinary call go on working untouched while the new one needs no ceremony.
describe 'how a set says it is counted' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_timed_movement(@token.account_id)
  end

  it 'reads a duration alone as a timed set' do
    log(@token.raw, exercise: @exercise.name, duration_seconds: 60)

    assert_equal Tectonic::Measured::TIME, logged_set.measure
  end

  it 'reads reps alone as a counted set, exactly as before' do
    log(@token.raw, exercise: @exercise.name, reps: 5, weight: 135)

    assert_equal Tectonic::Measured::REPS, logged_set.measure
    assert_equal 5, logged_set.reps
  end

  it 'takes the measure the caller gives over the one it would infer' do
    log(@token.raw, exercise: @exercise.name, measure: 'time', duration_seconds: 60)

    assert_equal Tectonic::Measured::TIME, logged_set.measure
  end
end

# `sets_measures_one_way` is reps XOR duration, matched to measure. Reaching it produces a
# check violation, which arrives at a model as "The tool failed unexpectedly and made no
# change" -- #213's shape. Every way in is refused with a sentence instead.
describe 'a set that cannot say how it was counted' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_timed_movement(@token.account_id)
  end

  # Sixty reps and sixty seconds are different sets, so with nothing saying which this is,
  # inferring either would be the tool deciding what somebody trained.
  it 'refuses reps and a duration together rather than picking one' do
    log(@token.raw, exercise: @exercise.name, reps: 5, duration_seconds: 60)

    assert tool_result['isError']
    assert_includes said, 'cannot be both counted and timed'
  end

  it 'takes both once the caller says which one counts' do
    log(@token.raw, exercise: @exercise.name, measure: 'reps', reps: 5, duration_seconds: 60)

    assert tool_result['isError'], 'a counted set still cannot carry a duration'
    assert_includes said, 'cannot also carry a duration'
  end
end

describe 'a set sent with the wrong count for the measure it named' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_timed_movement(@token.account_id)
  end

  it 'refuses neither, and says what the other option is' do
    log(@token.raw, exercise: @exercise.name, weight: 135)

    assert tool_result['isError']
    assert_includes said, 'duration_seconds'
  end

  it 'refuses a timed set sent with reps, naming what it wanted instead' do
    log(@token.raw, exercise: @exercise.name, measure: 'time', reps: 5)

    assert tool_result['isError']
    assert_includes said, 'needs duration_seconds'
  end
end

# A rating is reps in reserve, so a held position has none -- #211's rule, which the column
# also holds. It could not be reached from this tool before, because every set it wrote was
# counted in reps.
describe 'rating a set counted in seconds' do
  include Rack::Test::Methods
  include TimedSets

  it 'is refused rather than written' do
    token = mint(scopes: %w[read write])
    exercise = a_timed_movement(token.account_id)

    log(token.raw, exercise: exercise.name, duration_seconds: 60, rpe: 8)

    assert tool_result['isError']
  end
end

# How the room was set up, which the prescription side has recorded since #412 and the logging
# side had no way to say -- so a set logged outside a generated session lost the bench angle
# and pin heights the lift it came from carries.
describe 'recording how the room was set up' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_timed_movement(@token.account_id, name: 'Incline Bench')
  end

  it 'records the bench angle and the pin heights' do
    log(@token.raw, exercise: @exercise.name, reps: 5, weight: 135,
                    bench_angle_degrees: 30, rack_hole: 12, safety_hole: 6)

    assert_equal [30, 12, 6],
                 [logged_set.bench_angle_degrees, logged_set.rack_hole, logged_set.safety_hole]
  end

  it 'range-checks them the way the prescription side does' do
    log(@token.raw, exercise: @exercise.name, reps: 5, bench_angle_degrees: 120)

    assert tool_result['isError']
  end
end

# Correcting one afterwards, which is the other half: a duration that can be written and not
# revised is a number you have to delete a set to fix.
describe 'correcting a set counted in seconds' do
  include Rack::Test::Methods
  include TimedSets

  before do
    @token = mint(scopes: %w[read write])
    exercise = a_timed_movement(@token.account_id)
    log(@token.raw, exercise: exercise.name, duration_seconds: 4020)
    @set = logged_set
  end

  def revise(**arguments)
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, **arguments })
  end

  it 'takes a corrected duration' do
    revise(duration_seconds: 3600)

    refute tool_result['isError'], said
    assert_equal 3600, @set.refresh.duration_seconds
  end

  # This used to reach the check constraint and come back as "The tool failed unexpectedly and
  # made no change", which tells a model nothing it can act on. The tool takes no `measure` on
  # purpose -- a plank stays a plank -- so the refusal names the measure the set already has.
  it 'refuses reps rather than failing unexpectedly' do
    revise(reps: 5)

    assert tool_result['isError']
    assert_includes said, 'counted in seconds'
    refute_includes said, 'failed unexpectedly'
  end
end

describe 'correcting a set counted in reps' do
  include Rack::Test::Methods
  include TimedSets

  it 'refuses a duration' do
    token = mint(scopes: %w[read write])
    exercise = a_timed_movement(token.account_id)
    log(token.raw, exercise: exercise.name, reps: 5)
    counted = logged_set

    call_tool('update_set', raw: token.raw, arguments: { set_id: counted.id, duration_seconds: 60 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'counted in reps'
  end
end

