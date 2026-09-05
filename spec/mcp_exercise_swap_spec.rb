# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# #365: update_set could swap a movement one set at a time, which meant three calls for
# three sets and six on a lift with a ramp. The decision is made standing at the rack
# against a hard stop, so the friction had a real cost -- on 2026-09-01 three sets went into
# the log as Dumbbell Overhead Press because logging the wrong movement was quicker than
# correcting it.
#
# The constraint this tool works under is #364: a set already marked as lifted records a
# movement that was performed, and a swap says a different one was. So the interesting cases
# here are all about the line between the sets still standing as prescription and the ones
# that are now history.
module Swap
  def session_of(account_id, name, count: 3, completed: 0)
    exercise = Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}",
                                         is_barbell: false)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    count.times do |index|
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 65,
                                  reps: 5, is_warmup: false,
                                  **Tectonic::WorkoutSet.completion(index < completed))
    end
    [workout, exercise]
  end

  def sets_on(workout) = workout.sets_dataset.order(:id).all

  # The call under test, named once. Every case here differs only in the two movements and
  # what the session already holds, so spelling the call out each time buried that.
  def swap(raw, workout, from, into)
    call_tool('update_workout_exercise', raw:,
                                         arguments: { workout_id: workout.id, from_exercise: from, to_exercise: into })
  end
end

describe 'swapping a movement across a written session' do
  include Rack::Test::Methods
  include Swap

  before do
    @token = mint(scopes: %w[read write])
    @workout, @from = session_of(@token.account_id, 'Dumbbell Overhead Press')
  end

  it 'moves every set in one call' do
    swap(@token.raw, @workout, @from.name, 'Barbell Overhead Press')

    refute tool_result['isError']
    assert_equal 3, tool_result['structuredContent']['moved']
    assert_equal ['Barbell Overhead Press'], sets_on(@workout).map { |set| set.exercise.name }.uniq
  end

  # The rule update_set and the web editor both follow: plate math describing the movement
  # that was swapped out is worse than none at all.
  it 'takes the new movement plate math with it' do
    swap(@token.raw, @workout, @from.name, 'Back Squat')

    assert sets_on(@workout).all?(&:is_barbell)
  end

  it 'leaves the loads and reps exactly as they were' do
    swap(@token.raw, @workout, @from.name, 'Barbell Overhead Press')

    assert_equal([65, 65, 65], sets_on(@workout).map { |set| Tectonic::Plates.numeric(set.weight) })
    assert_equal [5, 5, 5], sets_on(@workout).map(&:reps)
  end
end

# The #364 boundary, which is the whole reason this tool is not just a bulk update_set.
describe 'swapping a session that has already been part lifted' do
  include Rack::Test::Methods
  include Swap

  before do
    @token = mint(scopes: %w[read write])
    @workout, @from = session_of(@token.account_id, 'Dumbbell Overhead Press', count: 3, completed: 2)
  end

  it 'moves the sets still standing as prescription' do
    swap(@token.raw, @workout, @from.name, 'Barbell Overhead Press')

    assert_equal 1, tool_result['structuredContent']['moved']
  end

  it 'leaves the lifted ones on the movement they record' do
    swap(@token.raw, @workout, @from.name, 'Barbell Overhead Press')

    assert_equal 2, tool_result['structuredContent']['left_lifted']
    lifted = sets_on(@workout).select(&:is_completed)

    assert_equal [@from.id, @from.id], lifted.map(&:exercise_id)
  end

  # Silently moving three and mentioning nothing would be the same failure #364 is about,
  # one level up: the count has to be said or the caller cannot tell what it got.
  it 'says what it left behind and why' do
    swap(@token.raw, @workout, @from.name, 'Barbell Overhead Press')
    text = tool_result.dig('content', 0, 'text')

    assert_includes text, 'Left 2 set(s) already marked as lifted'
    assert_includes text, 'delete and re-create'
  end
end

describe 'swapping a session that is entirely lifted' do
  include Rack::Test::Methods
  include Swap

  # #364 arriving through this door, and answered the same way rather than with a partial
  # success over nothing.
  it 'refuses rather than reporting a swap of zero sets' do
    token = mint(scopes: %w[read write])
    workout, from = session_of(token.account_id, 'Dumbbell Overhead Press', count: 2, completed: 2)
    swap(token.raw, workout, from.name, 'Barbell Overhead Press')

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'record what was actually performed'
    assert_equal [from.id, from.id], sets_on(workout).map(&:exercise_id)
  end
end

describe 'a swap that names something that is not there' do
  include Rack::Test::Methods
  include Swap

  before do
    @token = mint(scopes: %w[read write])
    @workout, = session_of(@token.account_id, 'Dumbbell Overhead Press')
  end

  # Resolver.exercise find-or-creates, which is right when a set is being written and
  # exactly wrong here: a typo would invent a movement, match none of it, and report a
  # successful swap of nothing.
  it 'refuses a movement the session does not contain, without creating it' do
    swap(@token.raw, @workout, 'Hack Squat', 'Back Squat')

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No sets of "Hack Squat"'
    assert_empty Tectonic::Exercise.where(account_id: @token.account_id, name: 'Hack Squat').all
  end

  it "refuses another account's session rather than reading it as empty" do
    stranger = mint(scopes: %w[read write]).raw
    swap(stranger, @workout, 'Anything', 'Back Squat')

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No workout with id'
  end
end

describe 'a swap that changes nothing' do
  include Rack::Test::Methods
  include Swap

  # An assistant re-sending a call it already made should not read its own no-op as having
  # moved something.
  it 'says so rather than counting a move' do
    token = mint(scopes: %w[read write])
    workout, from = session_of(token.account_id, 'Dumbbell Overhead Press')
    swap(token.raw, workout, from.name, from.name)

    refute tool_result['isError']
    assert_equal 0, tool_result['structuredContent']['moved']
    assert_includes tool_result.dig('content', 0, 'text'), 'nothing to swap'
  end
end

