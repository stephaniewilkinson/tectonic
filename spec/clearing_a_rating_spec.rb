# frozen_string_literal: true

# #722. A rating written by mistake could not be unwritten: update_set took rpe as an
# integer 1-10 and nothing else, so the way out was deleting the set, and the replacement
# carried no prescription. And a single session's target could not be set at all, which is
# how an agent holding only `rpe` came to write the target into it.

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require 'securerandom'

module ClearingARating
  def a_planned_set(account_id, **columns)
    exercise_id = DB[:exercises].insert(name: "Bench #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 150, reps: 5, is_warmup: false,
                     is_barbell: true, is_completed: false, planned_weight: 150, planned_reps: 5,
                     planned_rpe: 8, **columns)
  end

  def row(id) = DB[:sets].where(id:).first

  def update(minted, **arguments)
    call_tool('update_set', raw: minted.raw, arguments:)
    tool_result
  end
end

describe 'clearing a rating with update_set' do
  include Rack::Test::Methods
  include ClearingARating

  before { @minted = mint(scopes: %w[read write]) }

  it 'clears a mistaken rating and keeps the prescription' do
    id = a_planned_set(@minted.account_id, rpe: 7)

    refute update(@minted, set_id: id, rpe: nil)['isError']

    assert_nil row(id)[:rpe]
    assert_equal [150, 5, 8], row(id).values_at(:planned_weight, :planned_reps, :planned_rpe).map(&:to_i)
  end

  it 'sets and clears a target on one set' do
    id = a_planned_set(@minted.account_id)

    update(@minted, set_id: id, planned_rpe: 7)
    assert_equal 7, row(id)[:planned_rpe]

    update(@minted, set_id: id, planned_rpe: nil)
    assert_nil row(id)[:planned_rpe]
  end

  it 'refuses a target on a warmup, by name rather than as a database error' do
    id = a_planned_set(@minted.account_id, planned_rpe: nil, is_warmup: true)

    result = update(@minted, set_id: id, planned_rpe: 7)

    assert result['isError']
    assert_includes result.dig('content', 0, 'text'), 'working set counted in reps'
  end
end

