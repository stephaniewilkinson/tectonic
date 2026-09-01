# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require 'securerandom'

# What every reader sees when a session was not being trained the whole time it was open. #318.
#
# The arithmetic is in timing_spec.rb; what is here is that all four surfaces say it. That is
# the part #281 got wrong rather than the subtraction: the record page has printed a discarded
# gap count since it shipped, and neither MCP sentence carried one -- so an assistant reading
# "24h 9m" got the figure with nothing on it to say that all but nine minutes of it was the
# lifter asleep.
module ActiveTime
  # The reported case, to the minute. One set late on a Sunday, three the next morning three
  # minutes apart: 24h 6m of wall clock over six minutes of training.
  def a_session_split_by_a_night(account_id)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    night = 24 * 60 * 60
    [night + 360, 360, 180, 0].each { |ago| a_set(workout_id, exercise_id, ago) }
    workout_id
  end

  # An ordinary session, three sets six minutes apart end to end, with nothing to trim.
  def an_unbroken_session(account_id)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    [360, 180, 0].each { |ago| a_set(workout_id, exercise_id, ago) }
    workout_id
  end

  def a_set(workout_id, exercise_id, ago)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                     is_barbell: true, is_completed: true, completed_at: Time.now - ago)
  end
end

describe 'the record of a session that spanned a night' do
  include Rack::Test::Methods
  include RouteOwnership
  include ActiveTime

  before do
    @account_id = login
    get "/workouts/#{a_session_split_by_a_night(@account_id)}/"
  end

  it 'says how much of it was training' do
    assert_includes last_response.body, '6m active'
  end

  # Beside it rather than instead of it. The active figure rests on LONG_GAP_SECONDS, which
  # timing.rb admits is a defended guess -- the raw span next to it is what stops the guess
  # from destroying anything.
  it 'still says how long the session was open' do
    assert_includes last_response.body, '24h 6m elapsed'
  end

  it 'says how many gaps it took out' do
    assert_includes last_response.body, '1 long gap not counted'
  end
end

# Two numbers where there is only one thing to say would be saying it twice, on a line that is
# already three clauses long.
describe 'the record of an ordinary session' do
  include Rack::Test::Methods
  include RouteOwnership
  include ActiveTime

  it 'gives one length and does not call it active' do
    account_id = login
    get "/workouts/#{an_unbroken_session(account_id)}/"

    assert_includes last_response.body, '6m'
    refute_includes last_response.body, 'active'
  end
end

# The surface that needed this most: a sentence is all many clients render, which is #262's
# lesson, and this one carried the misleading number with no flag on it at all.
describe 'get_workout on a session that spanned a night' do
  include Rack::Test::Methods
  include ActiveTime

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id = a_session_split_by_a_night(@minted.account_id)
    call_tool('get_workout', raw: @minted.raw, arguments: { workout_id: @workout_id })
  end

  it 'gives both lengths and the reason they differ, in the prose' do
    assert_includes tool_result.dig('content', 0, 'text'), '6m active over 24h 6m elapsed'
    assert_includes tool_result.dig('content', 0, 'text'), '1 long gap not counted'
  end

  it 'gives both in the payload' do
    assert_equal 360, tool_result.dig('structuredContent', 'timing', 'active')
    assert_equal 86_760, tool_result.dig('structuredContent', 'timing', 'overall')
  end

  # The estimate was sound all along -- LONG_GAP_SECONDS has protected the median since #281 --
  # and it stays sound, which is what makes #263's per-movement pacing safe to keep resting on.
  it 'leaves the typical turnaround alone' do
    assert_equal 180, tool_result.dig('structuredContent', 'timing', 'typical_turnaround')
  end
end

describe 'get_workout on an ordinary session' do
  include Rack::Test::Methods
  include ActiveTime

  it 'reads exactly as it did, with one length' do
    minted = mint(scopes: %w[read write])
    workout_id = an_unbroken_session(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    refute_includes tool_result.dig('content', 0, 'text'), 'active'
    assert_equal tool_result.dig('structuredContent', 'timing', 'overall'),
                 tool_result.dig('structuredContent', 'timing', 'active')
  end
end

# A month of sessions is where a 24-hour figure does the most damage: it makes "are my
# sessions getting longer" unanswerable, and nothing in the row said which one to distrust.
describe 'a session that spanned a night in a list' do
  include Rack::Test::Methods
  include ActiveTime

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id = a_session_split_by_a_night(@minted.account_id)
    call_tool('list_workouts', raw: @minted.raw, arguments: {})
  end

  it 'spells the pair tightly enough for one line' do
    assert_includes tool_result.dig('content', 0, 'text'), '6m active of 24h 6m'
  end

  it 'carries both numbers and the gap count in the payload' do
    row = tool_result.dig('structuredContent', 'workouts').find { |w| w['id'] == @workout_id }

    assert_equal 360, row.dig('timing', 'active_seconds')
    assert_equal 86_760, row.dig('timing', 'seconds')
    assert_equal 1, row.dig('timing', 'long_gaps')
  end
end

describe 'an ordinary session in a list' do
  include Rack::Test::Methods
  include ActiveTime

  it 'reads as one length, as it did' do
    minted = mint(scopes: %w[read write])
    workout_id = an_unbroken_session(minted.account_id)

    call_tool('list_workouts', raw: minted.raw, arguments: {})
    row = tool_result.dig('structuredContent', 'workouts').find { |w| w['id'] == workout_id }

    refute_includes tool_result.dig('content', 0, 'text'), 'active'
    assert_equal 0, row.dig('timing', 'long_gaps')
  end
end

