# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# A set logged under the wrong movement can be put right. #463.
#
# #364 refuses to move a set that is marked as lifted, and it is right about what it was
# written for. A **swap** says a different movement was performed, and the load and reps on
# the row are then describing something that did not happen -- there is no reading under which
# they survive, so the honest answer is a new set.
#
# It is wrong about a **mis-record**, which wears the same shape and is a different claim. On
# 2026-09-01 three sets went into the log as Dumbbell Overhead Press at 45/65/65 because
# changing the movement mid-session cost more than living with it. The barbell is what was
# lifted. The load and reps are *true*; only the label is wrong, applied by somebody who could
# not change it at the moment they needed to. Refusing that is not protecting history, it is
# preserving a known error in it -- and the route out, delete and re-create, costs twice the
# calls the friction did.
#
# `relabel` and not the existing `confirm`, deliberately: confirm answers "yes, overwrite what
# this completed set measured", and these are different questions about the same row.
module Relabelling
  def a_session_logged_as(account_id, name, count: 3)
    exercise = Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}",
                                         is_barbell: false)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    [45, 65, 65].first(count).each do |weight|
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight:,
                                  reps: 5, is_warmup: false, **Tectonic::WorkoutSet.completion(true))
    end
    [workout, exercise]
  end

  def a_movement(account_id, name)
    Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: true)
  end

  def said = tool_result.dig('content', 0, 'text')

  def sets_on(workout) = workout.sets_dataset.order(:id).all
end

describe 'relabelling one lifted set' do
  include Rack::Test::Methods
  include Relabelling

  before do
    @token = mint(scopes: %w[read write])
    @workout, @from = a_session_logged_as(@token.account_id, 'Dumbbell Overhead Press', count: 1)
    @into = a_movement(@token.account_id, 'Barbell Overhead Press')
    @set = sets_on(@workout).first
  end

  def relabel(**extra)
    call_tool('update_set', raw: @token.raw,
                            arguments: { set_id: @set.id, exercise: @into.name, **extra })
  end

  it 'is still refused without saying so' do
    relabel

    assert tool_result['isError']
    assert_equal @from.id, @set.refresh.exercise_id
  end

  it 'moves the set once the caller says the name is what was wrong' do
    relabel(relabel: true)

    refute tool_result['isError'], said
    assert_equal @into.id, @set.refresh.exercise_id
  end
end

# The whole point of calling it a relabel rather than a swap: the work is true, so it survives
# the correction intact.
describe 'what relabelling one lifted set keeps' do
  include Rack::Test::Methods
  include Relabelling

  before do
    @token = mint(scopes: %w[read write])
    @workout, @from = a_session_logged_as(@token.account_id, 'Dumbbell Overhead Press', count: 1)
    @into = a_movement(@token.account_id, 'Barbell Overhead Press')
    @set = sets_on(@workout).first
    call_tool('update_set', raw: @token.raw,
                            arguments: { set_id: @set.id, exercise: @into.name, relabel: true })
  end

  it 'leaves the load and reps exactly as they were' do
    assert_equal 45, Tectonic::Plates.numeric(@set.refresh.weight)
    assert_equal 5, @set.refresh.reps
    assert @set.refresh.is_completed
  end

  # Through WorkoutSet.moved_to, so a relabelled set takes the new movement's plate math and
  # drops the old one's prescription -- the same rule a swap follows (#406). Plate math
  # describing the movement that was not lifted is worse than none.
  it 'takes the new movement plate math with it' do
    assert @set.refresh.is_barbell
  end
end

# Every set is lifted, so without the flag this is #364's refusal arriving through the bulk
# door -- and it now names the way out rather than only the delete-and-recreate one.
describe 'a whole lift of lifted sets, without the flag' do
  include Rack::Test::Methods
  include Relabelling

  it 'is refused, and says what else the caller might mean' do
    token = mint(scopes: %w[read write])
    workout, from = a_session_logged_as(token.account_id, 'Dumbbell Overhead Press')
    into = a_movement(token.account_id, 'Barbell Overhead Press')

    call_tool('update_workout_exercise', raw: token.raw,
                                         arguments: { workout_id: workout.id, from_exercise: from.name,
                                                      to_exercise: into.name })

    assert tool_result['isError']
    assert_includes said, 'relabel: true'
  end
end

# The reported case, which is three sets rather than one -- and the reason delete-and-recreate
# was not an answer: it costs six calls where the friction that caused the problem cost three.
describe 'relabelling a whole lift in one call' do
  include Rack::Test::Methods
  include Relabelling

  before do
    @token = mint(scopes: %w[read write])
    @workout, @from = a_session_logged_as(@token.account_id, 'Dumbbell Overhead Press')
    @into = a_movement(@token.account_id, 'Barbell Overhead Press')
  end

  def swap(**extra)
    call_tool('update_workout_exercise', raw: @token.raw,
                                         arguments: { workout_id: @workout.id, from_exercise: @from.name,
                                                      to_exercise: @into.name, **extra })
  end

  it 'moves all three at once, with the loads that were actually lifted' do
    swap(relabel: true)

    refute tool_result['isError'], said
    assert_equal [@into.id] * 3, sets_on(@workout).map(&:exercise_id)
    assert_equal([45, 65, 65], sets_on(@workout).map { |set| Tectonic::Plates.numeric(set.weight) })
  end

  it 'keeps the loads that were actually lifted' do
    swap(relabel: true)

    assert_equal([45, 65, 65], sets_on(@workout).map { |set| Tectonic::Plates.numeric(set.weight) })
  end
end

describe 'what a bulk relabel reports' do
  include Rack::Test::Methods
  include Relabelling

  it 'says it relabelled rather than swapped, because they are different claims' do
    token = mint(scopes: %w[read write])
    workout, from = a_session_logged_as(token.account_id, 'Dumbbell Overhead Press')
    into = a_movement(token.account_id, 'Barbell Overhead Press')

    call_tool('update_workout_exercise', raw: token.raw,
                                         arguments: { workout_id: workout.id, from_exercise: from.name,
                                                      to_exercise: into.name, relabel: true })

    assert_includes said, 'Relabelled 3 set(s)'
    assert tool_result['structuredContent']['relabelled']
  end
end

# A relabel must not become the way a swap is done. The lifted/unlifted split is still the
# default, and the flag has to be asked for.
describe 'what a swap still does without the flag' do
  include Rack::Test::Methods
  include Relabelling

  it 'moves the unlifted sets and leaves the lifted ones' do
    token = mint(scopes: %w[read write])
    workout, from = a_session_logged_as(token.account_id, 'Dumbbell Overhead Press', count: 2)
    into = a_movement(token.account_id, 'Barbell Overhead Press')
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: from.id, weight: 65, reps: 5,
                                is_warmup: false, is_completed: false)

    call_tool('update_workout_exercise', raw: token.raw,
                                         arguments: { workout_id: workout.id, from_exercise: from.name,
                                                      to_exercise: into.name })

    assert_equal 1, tool_result['structuredContent']['moved']
    assert_equal 2, tool_result['structuredContent']['left_lifted']
    refute tool_result['structuredContent']['relabelled']
  end
end

