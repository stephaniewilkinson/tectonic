# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require 'securerandom'

# The three tools that look a movement up without writing one, resolving it the way the rest
# of the app does. #454.
#
# `exercise_history`, `block_progress` and `set_working_weight` each carried a lookup of their
# own -- `where(name: name.strip).order(:id).first` -- and it differed from `Exercise.matching`
# in two ways that both bite.
#
# **It did not fold the name**, so `bench press` resolved for `create_set` and was refused
# here. #474 settled that `Bench Press`, `bench press` and `Benchpress` are one movement, and
# a caller should not have to learn which tool believes that.
#
# **And it broke the tie by id.** A name can match two visible rows: the reporting account has
# a private `Deadlift` carrying 64 sets and seven program lifts, and a library `Deadlift` with
# nothing on it. `order(:id)` picks the private one there only because it happens to be older.
# Library ids run 7 to 88 on production, so for any account created after the seed every own
# row outranks them and the library row wins -- and "how has my deadlift gone" comes back
# "nothing logged" to somebody with five years of it.
module OneWayToNameAMovement
  # A seeded library movement to collide with. A real one rather than a written one: a row with
  # a nil account is how the library is spelled, so CleanDatabase deliberately keeps them and a
  # spec that invents one leaves it behind for every run after it.
  def a_library_movement
    Tectonic::Exercise.where(account_id: nil).order(:id).first ||
      raise('the seeded library is missing; run rake library:exercises against the test database')
  end

  def a_logged_set(account_id, exercise, weight: 315)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, reps: 5,
                     is_warmup: false, is_completed: true, is_barbell: true)
    workout_id
  end
end

describe 'naming a movement in a case nobody typed it in' do
  include Rack::Test::Methods
  include OneWayToNameAMovement

  before do
    @token = mint(scopes: %w[read write])
    @exercise = Tectonic::Exercise.create(name: "Bench Press #{SecureRandom.hex(4)}",
                                          account_id: @token.account_id, is_barbell: true)
    a_logged_set(@token.account_id, @exercise)
  end

  # The folded name is what create_set has resolved on since #474. A caller should not have to
  # learn which tool believes that.
  it 'finds it for exercise_history' do
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: @exercise.name.downcase })

    assert_includes tool_result.dig('content', 0, 'text'), @exercise.name
  end

  it 'finds it for block_progress' do
    call_tool('block_progress', raw: @token.raw, arguments: { exercise: @exercise.name.downcase })

    refute tool_result['isError'], 'a folded name should resolve here as it does for create_set'
  end

  it 'finds it for set_working_weight' do
    workout_id = a_logged_set(@token.account_id, @exercise)
    call_tool('set_working_weight', raw: @token.raw,
                                    arguments: { workout_id:, exercise: @exercise.name.downcase, weight: 200 })

    refute tool_result['isError']
  end
end

# Folding a name must not turn "I do not know that movement" into a guess at a nearby one.
# These three read and bulk-edit; creating a row to report emptily on it, or quietly picking
# the closest thing, is worse than saying the name is unknown.
describe 'a movement that really is not there' do
  include Rack::Test::Methods
  include OneWayToNameAMovement

  before { @token = mint(scopes: %w[read write]) }

  it 'is still refused rather than resolved to something near it' do
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: 'Zercher Sandbag Carry' })

    assert tool_result['isError']
  end
end

# The tie-break, which is the half that returns a wrong answer rather than a refusal.
describe 'a movement whose name a library row also has' do
  include Rack::Test::Methods
  include OneWayToNameAMovement

  before do
    @token = mint(scopes: %w[read write])
    @library = a_library_movement
    @name = @library.name
    @own = Tectonic::Exercise.create(name: @name, account_id: @token.account_id, is_barbell: true)
    a_logged_set(@token.account_id, @own)
  end

  # The account's own row is newer than the library's here, which is the ordering every
  # account created after the seed has. Ordering by id picked the library row, which has no
  # sets on it, and reported "nothing logged" about a movement with training on it.
  it 'reads the training off the lifter own row rather than the empty library one' do
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: @name })

    assert_equal @own.id, tool_result.dig('structuredContent', 'exercise_id')
  end

  it 'reports a set on it rather than an empty history' do
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: @name })

    refute_empty tool_result.dig('structuredContent', 'sets')
  end

  it 'picks the same row for block_progress' do
    call_tool('block_progress', raw: @token.raw, arguments: { exercise: @name })

    refute tool_result['isError']
  end
end

