# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # login, token helpers; idempotent require
require_relative 'mcp_spec' # mint, call_tool, tool_result; idempotent require

# #656. The watch's heart rate, read over a session's own window and set against each set.
#
# The fixture is the shape #579's probe found on the reporting account's watch: a reading every
# ten minutes until the watch noticed the workout, then one every fifteen seconds. The session
# below runs 10:00 to 10:20; the watch notices at 10:08.
module HeartRatePerSet
  START = Time.new(2026, 9, 20, 10, 0, 0)
  NOTICED = START + (8 * 60)

  def a_connection(account_id)
    Tectonic::WithingsConnection.store(account_id, { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
                                                     'expires_in' => 10_800, 'userid' => '9001' })
  end

  # Three sets: one before the watch noticed, two after, each Done four minutes apart from 10:04.
  def a_session_with_sets(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Date.new(2026, 9, 20))
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    @set_ids = [4, 12, 16].map do |minute|
      DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5, is_warmup: false,
                       is_completed: true, completed_at: START + (minute * 60))
    end
    DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5, is_warmup: false,
                     is_completed: true, completed_at: START + (20 * 60))
    workout_id
  end

  # The series as Withings sends it: unix seconds as string keys. Sparse before NOTICED; after
  # it every fifteen seconds, climbing to 150 in the minute before each Done and falling to 100.
  def series
    sparse.merge(dense).merge((START + 600).to_i.to_s => { 'model' => 93 }) # a sample with no heart rate
  end

  def sparse = [START - 60, START + 180].to_h { |at| [at.to_i.to_s, reading(95)] }

  def dense
    (NOTICED.to_i..(START + (21 * 60)).to_i).step(15).to_h { |at| [at.to_s, reading(effort(Time.at(at)))] }
  end

  def effort(at)
    [12, 16, 20].any? { |minute| (START + (minute * 60) - at).between?(-15, 60) } ? 150 : 100
  end

  def reading(bpm) = { 'heart_rate' => bpm, 'model' => 93, 'deviceid' => 'x' }

  def press(body = { 'series' => series })
    get "/workouts/#{@workout_id}"
    token = last_response.body[%r{action="/workouts/\d+/withings/heart-rate".*?name="_csrf" value="([^"]+)"}m, 1]
    answering_with(body) { post "/workouts/#{@workout_id}/withings/heart-rate", { '_csrf' => token } }
  end

  def answering_with(body, &)
    Tectonic::Withings.stub(:post, ->(_path, **_form) { body }, &)
  end
end

describe 'reading the watch for a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include HeartRatePerSet

  before do
    @account_id = login
    a_connection(@account_id)
    @workout_id = a_session_with_sets(@account_id)
  end

  it 'keeps every reading once, and drops a sample with no heart rate' do
    2.times { press }

    assert_equal series.count { |_, r| r['heart_rate'] }, DB[:heart_rates].where(account_id: @account_id).count
  end

  it 'says which part of the session the readings cover' do
    press
    follow_redirect!

    assert_includes last_response.body, 'recorded heart rate every few seconds from'
    assert_includes last_response.body, 'Sets outside that stretch'
  end

  it 'gives each set measured densely its peak and the lowest point before the next' do
    press
    follow_redirect!

    assert_includes last_response.body, '150, down to 100'
  end
end

describe 'the heart rate box before and after asking' do
  include Rack::Test::Methods
  include RouteOwnership
  include HeartRatePerSet

  before do
    @account_id = login
    a_connection(@account_id)
    @workout_id = a_session_with_sets(@account_id)
  end

  it 'offers to read it, and nothing is fetched on a view' do
    get "/workouts/#{@workout_id}"

    assert_includes last_response.body, 'Read heart rate from the watch'
  end

  it 'says so when Withings does not answer' do
    press(nil)
    follow_redirect!

    assert_includes last_response.body, 'Withings did not answer'
  end
end

describe 'the figures a set is given' do
  include HeartRatePerSet

  def sets
    [4, 12, 16, 20].map.with_index { |minute, id| { id:, completed_at: HeartRatePerSet::START + (minute * 60) } }
  end

  def readings = series.filter_map { |at, r| [Time.at(at.to_i), r['heart_rate']] if r['heart_rate'] }.sort

  # The set before the watch noticed has one sparse reading near it, and its figure says so:
  # a peak off one reading is a different claim from a peak off a dozen.
  it 'says a set the watch was not densely recording rests on one reading' do
    assert_equal 1, Tectonic::HeartRates.per_set(sets, readings)[0][:peak_readings]
  end

  it 'counts the readings each figure rests on' do
    figure = Tectonic::HeartRates.per_set(sets, readings)[1]

    assert_equal 150, figure[:peak]
    assert_equal 100, figure[:low_before_next]
    assert_operator figure[:peak_readings], :>, 4
  end

  it 'finds the dense stretch, not the sparse readings before it' do
    from, = Tectonic::HeartRates.dense_stretch(readings)

    assert_equal HeartRatePerSet::NOTICED, from
  end
end

describe 'heart rate for an assistant' do
  include Rack::Test::Methods
  include HeartRatePerSet

  it 'is on get_workout, per set, with how many readings each figure rests on' do
    token = mint(scopes: ['read'])
    workout_id = a_session_with_sets(token.account_id)
    Tectonic::HeartRates.store(token.account_id, series)
    call_tool('get_workout', raw: token.raw, arguments: { workout_id: })
    detail = tool_result['structuredContent']
    second = detail['sets'][1]['heart_rate']

    assert_equal 150, second['peak']
    assert_equal 100, second['low_before_next']
    assert_operator detail['heart_rate']['readings'], :>, 40
  end
end

describe 'a set the watch barely measured, on the record page' do
  include Rack::Test::Methods
  include RouteOwnership
  include HeartRatePerSet

  it 'says how many readings its figure rests on' do
    account_id = login
    workout_id = a_session_with_sets(account_id)
    Tectonic::HeartRates.store(account_id, series)
    get "/workouts/#{workout_id}"

    assert_includes last_response.body, '95 (1 reading)'
  end
end

