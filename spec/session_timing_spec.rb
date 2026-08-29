# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/timing'

# The stamps themselves: who writes one, who clears one, and what refuses a row carrying one
# without the completion that justifies it. #281.
#
# The arithmetic is in timing_spec.rb. What is here is the part that can only go wrong
# against a real database and a real request: four write paths flip is_completed, and a path
# that clears the flag without clearing the stamp is a check violation surfacing as a 500 on
# a Done button, which is #213's failure shape.
module SessionTiming
  def scratch_workout(account_id)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    [workout_id, exercise_id]
  end

  def written_set(workout_id, exercise_id, **overrides)
    DB[:sets].insert({ workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: false, is_barbell: true }.merge(overrides))
  end

  def stamp_of(set_id) = DB[:sets].where(id: set_id).get(:completed_at)

  def done?(set_id) = DB[:sets].where(id: set_id).get(:is_completed)
end

# The rule the database will not let anybody forget: a set that was never done cannot carry
# the instant it was done.
describe 'the constraint under the stamp' do
  include SessionTiming

  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @workout_id, @exercise_id = scratch_workout(@account_id)
  end

  it 'refuses a stamp on a set that was never completed' do
    assert_raises(Sequel::CheckConstraintViolation) do
      written_set(@workout_id, @exercise_id, is_completed: false, completed_at: Time.now)
    end
  end

  # `is_completed IS TRUE` rather than `= true`, because the column is nullable and
  # `NULL = true` is NULL, which a CHECK treats as satisfied.
  it 'refuses a stamp on a set whose completion is null' do
    assert_raises(Sequel::CheckConstraintViolation) do
      written_set(@workout_id, @exercise_id, is_completed: nil, completed_at: Time.now)
    end
  end

  it 'allows a completed set to carry one' do
    id = written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now)

    refute_nil stamp_of(id)
  end
end

# The tap that stamps, and the tap that takes it back.
describe 'marking a set done from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  def tap(fields = {})
    path = "/workouts/#{@workout_id}/sets/#{@set_id}/complete"
    post path, fields.merge('_csrf' => token_for_form("/workouts/#{@workout_id}/session", path))
  end

  it 'stamps it when Done is tapped' do
    tap

    assert done?(@set_id)
    refute_nil stamp_of(@set_id)
  end

  # A set un-completed was not done, so the instant it was done is no longer a fact -- and
  # keeping it would leave a turnaround measured against a set the lifter says did not
  # happen. This is also the path the constraint would 500 on if the two ever came apart.
  it 'clears the stamp when the tap is undone' do
    tap
    tap

    refute done?(@set_id)
    assert_nil stamp_of(@set_id)
  end
end

# The two ways into the same route that are not a bare tap. They differ, and the difference
# is the whole of #215 read onto the stamp.
describe 'rating a set and correcting one' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  def tap(fields = {})
    path = "/workouts/#{@workout_id}/sets/#{@set_id}/complete"
    post path, fields.merge('_csrf' => token_for_form("/workouts/#{@workout_id}/session", path))
  end

  it 'stamps it when a rating is submitted, because rating one is saying you lifted it' do
    tap('rpe' => '8')

    assert done?(@set_id)
    refute_nil stamp_of(@set_id)
  end

  # Correcting a weight two reps into a set is not doing the set. #215 stopped a revision
  # completing a set; this is the same rule for the stamp, and getting it wrong would move a
  # turnaround the lifter never took.
  it 'leaves the stamp alone when only a correction is saved' do
    tap('weight' => '145')

    refute done?(@set_id)
    assert_nil stamp_of(@set_id)
  end
end

# The other place a checkbox can un-complete a set. It is the quiet one, and the one most
# likely to be left behind by a change made on the session screen.
describe 'the set edit form' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now)
  end

  def save(fields)
    path = "/workouts/#{@workout_id}/sets/#{@set_id}"
    post path, fields.merge('_csrf' => token_for_form("/workouts/#{@workout_id}/sets/#{@set_id}/edit", path))
  end

  it 'clears the stamp when the completed box is unticked' do
    save('weight' => '155', 'reps' => '5')

    refute done?(@set_id)
    assert_nil stamp_of(@set_id)
  end

  it 'keeps a stamp when the box stays ticked' do
    save('weight' => '155', 'reps' => '5', 'is_completed' => 'on')

    assert done?(@set_id)
    refute_nil stamp_of(@set_id)
  end
end

describe 'completing a set over MCP' do
  include Rack::Test::Methods
  include SessionTiming

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id, @exercise_id = scratch_workout(@minted.account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  it 'stamps it the same way the screen does' do
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })

    refute_nil stamp_of(@set_id)
  end

  it 'clears the stamp when the completion is undone' do
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id, completed: false })

    refute done?(@set_id)
    assert_nil stamp_of(@set_id)
  end

  # A set logged as already done is stamped with when it was logged, which is the best this
  # path can say -- and a set logged as written carries no stamp at all.
  it 'stamps a set created as already lifted, and not one created as written' do
    call_tool('create_set', raw: @minted.raw,
                            arguments: { exercise: 'Back Squat', weight: 155, reps: 5, is_completed: true })
    lifted = DB[:sets].order(:id).last

    refute_nil lifted[:completed_at]

    call_tool('create_set', raw: @minted.raw, arguments: { exercise: 'Back Squat', weight: 155, reps: 5 })

    assert_nil DB[:sets].order(:id).last[:completed_at]
  end
end

# The session header, which is where a running session is read.
describe 'the session screen clock' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
  end

  def stamped(*offsets)
    offsets.each do |offset|
      written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - offset)
    end
    get "/workouts/#{@workout_id}/session"
    last_response.body
  end

  it 'says how long the session has been going once there is a span to measure' do
    body = stamped(600, 0)

    assert_includes body, 'id="session-clock"'
    assert_includes body, 'so far'
  end

  # Server-rendered first, so a browser with JavaScript off shows the length as at page
  # load rather than nothing at all. The attribute is what the ticker counts on from.
  it 'renders the elapsed seconds for the ticker to count on from' do
    assert_match(/data-elapsed="\d+"/, stamped(600, 0))
  end
end

# Before there is a span, there is nothing honest to show. A session with one completed set
# has a beginning and no length, and "0m" would be a claim about training that has not
# happened yet.
describe 'the session screen before there is a span to measure' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  it 'draws no clock at all' do
    account_id = login
    workout_id, exercise_id = scratch_workout(account_id)
    written_set(workout_id, exercise_id)
    get "/workouts/#{workout_id}/session"

    refute_includes last_response.body, 'id="session-clock"'
  end
end

# The anchor spec/session_progress_spec.rb reads the bar with. The clock lives inside that
# paragraph rather than in a row around it precisely so the regex keeps matching -- markup
# that moved the tag would make that spec read an empty string and pass for the wrong reason.
describe 'where the clock sits in the header' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  it 'keeps the set count in the paragraph that closes the progress bar' do
    account_id = login
    workout_id, exercise_id = scratch_workout(account_id)
    2.times { |i| written_set(workout_id, exercise_id, is_completed: true, completed_at: Time.now - (600 * (1 - i))) }
    get "/workouts/#{workout_id}/session"

    assert_includes last_response.body, '<p class="mt-1'
    assert_includes last_response.body, 'of 2 sets'
  end
end

# The record, where a finished session is read back.
describe 'the workout record' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
  end

  it 'says how long it took and what a normal turnaround was' do
    [900, 780, 660].each do |ago|
      written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - ago)
    end
    get "/workouts/#{@workout_id}/"

    assert_includes last_response.body, 'between sets'
  end

  # "Turnaround" and never "rest": one tap per set measures rest plus the next set's working
  # time, and naming it rest would claim a number the app cannot see.
  it 'never calls a turnaround a rest' do
    [900, 780].each do |ago|
      written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - ago)
    end
    get "/workouts/#{@workout_id}/"

    refute_match(/\brest\b/i, last_response.body)
  end
end

# Every session trained before #281 shipped carries no stamps, and every one written but not
# yet trained carries none either. Both must read as silence rather than as a zero.
describe 'the workout record for an unstamped session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  it 'says nothing about how long it took' do
    account_id = login
    workout_id, exercise_id = scratch_workout(account_id)
    written_set(workout_id, exercise_id, is_completed: true)
    get "/workouts/#{workout_id}/"

    refute_includes last_response.body, 'between sets'
  end
end

describe 'get_workout on a measured session' do
  include Rack::Test::Methods
  include SessionTiming

  it 'reports how long it took, in the prose and in the payload' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise_id = scratch_workout(minted.account_id)
    [900, 780, 660].each do |ago|
      written_set(workout_id, exercise_id, is_completed: true, completed_at: Time.now - ago)
    end

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), 'between sets'
    assert_equal 240, tool_result.dig('structuredContent', 'timing', 'overall')
  end

  it 'says nothing about timing for a session with no stamps' do
    minted = mint(scopes: %w[read write])
    workout_id, exercise_id = scratch_workout(minted.account_id)
    written_set(workout_id, exercise_id, is_completed: true)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    refute_includes tool_result.dig('content', 0, 'text'), 'between sets'
    assert_nil tool_result.dig('structuredContent', 'timing', 'overall')
  end
end

