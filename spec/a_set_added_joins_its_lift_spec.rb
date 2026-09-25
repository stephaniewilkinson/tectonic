# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # login; idempotent require
require_relative 'mcp_spec' # mint, call_tool, tool_result; idempotent require

# The issues list, item 3. A set added to a session for a movement it already had landed at the
# end by id and opened a second panel of that movement after unrelated ones: clamshells in two
# places, "6 of 7" counted against neither, and a restore attempt that silently doubled them.
module JoiningALift
  def a_movement(account_id, name) = DB[:exercises].insert(name: "#{name} #{SecureRandom.hex(3)}", account_id:)

  def planned(workout_id, exercise_id, count)
    count.times do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 20, reps: 15, planned_weight: 20, planned_reps: 15,
                       is_warmup: false)
    end
  end

  def added(workout_id, exercise_id)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 20, reps: 15, is_warmup: false, is_completed: true,
                     completed_at: Time.now)
  end

  def panels(workout_id)
    get "/workouts/#{workout_id}/session"
    last_response.body.scan(/id="lift-panel-\d+"/).uniq.length
  end
end

describe 'a set added to a movement the session already has' do
  include Rack::Test::Methods
  include RouteOwnership
  include JoiningALift

  before do
    @account_id = login
    @workout = DB[:workouts].insert(account_id: @account_id, date: Date.today)
    @clamshell = a_movement(@account_id, 'Banded Clamshell')
    @face_pull = a_movement(@account_id, 'Band Face Pull')
    planned(@workout, @clamshell, 3)
    planned(@workout, @face_pull, 3)
  end

  it 'joins that movement on the session screen rather than opening a second panel' do
    added(@workout, @clamshell)

    assert_equal 2, panels(@workout)
  end

  # What the programme wrote twice stays twice: heavy bench, then back-off bench.
  it 'leaves a movement the plan lists twice as two' do
    planned(@workout, @clamshell, 2)

    assert_equal 3, panels(@workout)
  end
end

describe 'create_set for a movement the session already has' do
  include Rack::Test::Methods
  include JoiningALift

  before do
    @token = mint(scopes: %w[read write])
    @workout = DB[:workouts].insert(account_id: @token.account_id, date: Date.today)
    @clamshell = a_movement(@token.account_id, 'Banded Clamshell')
    @name = DB[:exercises].where(id: @clamshell).get(:name)
    planned(@workout, @clamshell, 3)
  end

  def log_one
    call_tool('create_set', raw: @token.raw,
                            arguments: { exercise: @name, reps: 15, weight: 20, is_completed: true })
  end

  it 'says which set of that movement it became' do
    log_one

    assert_includes tool_result.dig('content', 0, 'text'), 'set 4 of 4 of it in this session'
  end

  # One call made twice is the commonest way this goes wrong, and the reply says so.
  it 'points out a set identical to one logged a moment ago' do
    log_one
    log_one

    assert_includes tool_result.dig('content', 0, 'text'), 'less than two minutes ago'
  end
end

