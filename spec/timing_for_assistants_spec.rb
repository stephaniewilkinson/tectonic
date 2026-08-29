# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec'         # reuses its token minting and call_tool; idempotent require
require_relative 'query_count_spec' # and its queries_while tally; idempotent require
require_relative '../lib/tectonic/timing'

# Making the measurement usable by an assistant. #263.
#
# The issue asked for an estimator: minutes per set by kind, a time budget on the program,
# and a warning at generation. The owner's answer was that the app's job is to accurately
# represent how long a lifter takes, and the assistant's job is to judge -- so none of that
# model was built.
#
# What is here instead is the measurement, put where an assistant can price a session with
# it. #281 answers "how long did Monday take". This answers "how long does *this lifter*
# take, per movement and per session", which is the question you have to be able to answer
# before you can say whether a written day will fit in an hour.
module AssistantTiming
  def movement(account_id, name: "Lift #{SecureRandom.hex(4)}")
    Tectonic::Exercise.create(name:, account_id:, is_barbell: true)
  end

  # A session of one movement whose sets were completed at the given offsets in seconds
  # before now, oldest first.
  def session_of(account_id, exercise, *ago)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    ago.each do |seconds|
      DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                       is_warmup: false, is_completed: true, is_barbell: true,
                       completed_at: Time.now - seconds)
    end
    workout_id
  end
end

# The per-movement number, which is the one that prices a prescription: a day of five squat
# sets costs roughly five of these.
describe 'how long a set of one movement costs' do
  include Rack::Test::Methods
  include AssistantTiming

  before do
    @minted = mint(scopes: %w[read write])
    @exercise = movement(@minted.account_id)
  end

  def history
    call_tool('exercise_history', raw: @minted.raw, arguments: { exercise: @exercise.name })
    tool_result
  end

  it 'is the middle gap between consecutive sets of it' do
    session_of(@minted.account_id, @exercise, 600, 480, 360)

    assert_equal 120, history.dig('structuredContent', 'typical_turnaround_seconds')
  end

  # Many clients render only the text, which is #262's lesson.
  it 'is in the sentence as well as the payload' do
    session_of(@minted.account_id, @exercise, 600, 480, 360)

    assert_includes history.dig('content', 0, 'text'), 'between sets of it'
  end
end

# Every set trained before #281 shipped carries no stamp, and a zero here would read as
# instantaneous -- a claim about training rather than an absence of one.
describe 'a movement with nothing to measure' do
  include Rack::Test::Methods
  include AssistantTiming

  it 'says nothing, in the payload and in the sentence alike' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    workout_id = DB[:workouts].insert(account_id: minted.account_id, date: Time.now)
    2.times do
      DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                       is_warmup: false, is_completed: true, is_barbell: true)
    end

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_nil tool_result.dig('structuredContent', 'typical_turnaround_seconds')
    refute_includes tool_result.dig('content', 0, 'text'), 'between sets of it'
  end
end

# The grouping is the part that would be silently wrong. Two sets of the same movement in
# sessions a week apart are not a turnaround, and subtracting across that boundary would
# report a week as a rest between sets.
describe 'the same movement across two sessions' do
  include Rack::Test::Methods
  include AssistantTiming

  it 'never subtracts one session from another' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    session_of(minted.account_id, exercise, 600, 480)
    session_of(minted.account_id, exercise, 300, 180)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    # Two sessions of one 120s gap each. Ungrouped, the rows would also yield the 180s
    # between the sessions, and the median of three would be 150 rather than 120.
    assert_equal 120, tool_result.dig('structuredContent', 'typical_turnaround_seconds')
  end

  it 'is nothing at all for a movement lifted once per session and only once' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    session_of(minted.account_id, exercise, 600)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_nil tool_result.dig('structuredContent', 'typical_turnaround_seconds')
  end
end

# "Are my sessions getting longer" was a call per session before this.
describe 'listing workouts with how long each took' do
  include Rack::Test::Methods
  include AssistantTiming

  before do
    @minted = mint(scopes: %w[read write])
    @exercise = movement(@minted.account_id)
  end

  def listed
    call_tool('list_workouts', raw: @minted.raw)
    tool_result
  end

  it 'reports the length of each in the payload' do
    session_of(@minted.account_id, @exercise, 600, 480, 360)

    assert_equal 240, listed.dig('structuredContent', 'workouts', 0, 'timing', 'seconds')
  end

  it 'reports a typical turnaround beside it' do
    session_of(@minted.account_id, @exercise, 600, 480, 360)

    assert_equal 120, listed.dig('structuredContent', 'workouts', 0, 'timing', 'typical_turnaround_seconds')
  end

  it 'says how long in the row a text-only client reads' do
    session_of(@minted.account_id, @exercise, 600, 360)

    assert_match(/4m/, listed.dig('content', 0, 'text'))
  end
end

# A "0m" among twenty rows would read as a real session that took no time.
describe 'listing a session that was never stamped' do
  include Rack::Test::Methods
  include AssistantTiming

  it 'says nothing about how long it took' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    workout_id = DB[:workouts].insert(account_id: minted.account_id, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                     is_warmup: false, is_completed: true, is_barbell: true)

    call_tool('list_workouts', raw: minted.raw)

    assert_nil tool_result.dig('structuredContent', 'workouts', 0, 'timing', 'seconds')
  end
end

# The list loads every workout's sets to count them, and now to subtract their stamps too.
# Without eager loading that is a query a workout, which is #234's shape in the one list
# that had escaped it.
describe 'the cost of listing workouts' do
  include Rack::Test::Methods
  include AssistantTiming
  include QueryCount

  # The shape rather than a number, which is what query_count_spec argues for: what matters
  # is not that the call costs N queries but that it costs the same N when the account has
  # trained for a year.
  it 'does not grow a query per session in the page' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    3.times { session_of(minted.account_id, exercise, 600, 480) }
    small = queries_while { call_tool('list_workouts', raw: minted.raw) }

    3.times { session_of(minted.account_id, exercise, 600, 480) }
    large = queries_while { call_tool('list_workouts', raw: minted.raw) }

    assert_equal small, large, 'listing twice as many sessions issued more queries'
  end
end

