# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# #257. An MCP audit reported that exercise_history counts planned sets as performed, and
# so feeds a programme's own prescriptions back as if they were performance data.
#
# Checked against the tree, and the behaviour was already right: the dataset filters to
# is_completed unless a caller asks for include_planned, and Exercise#estimated_max is
# completed-only as well. So this file is the ticket, not the fix.
#
# It is worth having anyway, and worth more than most regression specs, because of how the
# failure would present. It is silent -- no error, no empty result, just numbers that are
# slightly too high -- and self-reinforcing, since the next block is built off them and
# writes prescriptions higher still. Nothing else in this suite would go red for it.
module HistoryScope
  def prose
    tool_result.dig('content', 0, 'text')
  end

  def payload
    tool_result['structuredContent']
  end

  # A movement with a session written against it and nothing lifted, which is exactly what
  # a generated week looks like the morning it is generated.
  def written(account_id, weight: 155, sets: 3)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    rows = Array.new(sets) do
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight:,
                                  reps: 5, planned_weight: weight, planned_reps: 5,
                                  is_warmup: false, is_completed: false)
    end
    [exercise, rows]
  end

  def history(token, exercise, arguments = {})
    call_tool('exercise_history', raw: token.raw, arguments: { exercise: exercise.name, **arguments })
  end
end

describe 'the history of a movement that has only been prescribed' do
  include Rack::Test::Methods
  include HistoryScope

  before do
    @token = mint(scopes: %w[read write])
    @exercise, @sets = written(@token.account_id)
  end

  # The assertion the audit asked for: writing a session must not move the history.
  it 'is empty, however many sets are sitting in the plan' do
    history(@token, @exercise)

    assert_equal 0, payload['shown']
    assert_includes prose, '0 set(s)'
    assert_includes prose, 'heaviest none'
  end

  it 'has no estimated max to hand a percentage-priced block' do
    history(@token, @exercise)

    assert_nil payload['estimated_1rm']
  end

  it 'moves the moment one set is actually lifted, and only by that one' do
    @sets.first.update(is_completed: true)
    history(@token, @exercise)

    assert_equal 1, payload['shown']
    assert_includes prose, 'heaviest 155'
    refute_nil payload['estimated_1rm']
  end
end

# The flag is the other half. A caller that genuinely wants to see what is planned can
# ask, and the ticket's reported symptom is what that answer looks like -- so covering
# only the default would leave the flag free to break, and leave a reader unable to tell
# a bug from a caller having asked for this.
describe 'the same history asked for with include_planned' do
  include Rack::Test::Methods
  include HistoryScope

  before do
    @token = mint(scopes: %w[read write])
    @exercise, = written(@token.account_id, sets: 3)
  end

  it 'counts the sets that are only written' do
    history(@token, @exercise, include_planned: true)

    assert_equal 3, payload['shown']
    assert_includes prose, '3 set(s)'
  end

  # Even here the max stays completed-only. It is the number a percentage-priced block
  # resolves against, so deriving it from work nobody has done is the circular failure
  # the ticket is about, flag or no flag.
  it 'still derives no estimated max from them' do
    history(@token, @exercise, include_planned: true)

    assert_nil payload['estimated_1rm']
  end
end

