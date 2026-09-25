# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'session_timing_spec'  # and its scratch_workout / written_set
require_relative '../lib/tectonic/timing'
require 'securerandom'

# When a session started and when it finished, on the record. #397.
#
# The arithmetic is not new: `overall` has always been the subtraction of exactly these two
# stamps. What is new is keeping the ends rather than only the difference, because "48m" and
# "48m, and it was the six o'clock session" answer different questions, and the second is the
# one somebody reading back a week of training is asking.
describe 'the two ends of a session' do
  it 'is the first stamp and the last' do
    first = Time.now - 3600
    last = Time.now - 600
    timing = Tectonic::Timing.session({ finished_at: nil },
                                      [{ completed_at: first }, { completed_at: last }])

    assert_equal first, timing[:started_at]
    assert_equal last, timing[:ended_at]
  end

  # The more honest end of a session whose last set was followed by ten minutes of putting
  # plates away -- and the same end `overall` already measures to.
  it 'ends where the lifter said they were done, not at the last set' do
    last = Time.now - 600
    said = Time.now - 60
    timing = Tectonic::Timing.session({ finished_at: said }, [{ completed_at: last }])

    assert_equal said, timing[:ended_at]
  end

  # Nil rather than a date at midnight. A session with no stamps has no beginning to report,
  # and inventing one would put a time on training that never happened.
  it 'says nothing about a session with no stamps' do
    timing = Tectonic::Timing.session({ finished_at: nil }, [{ completed_at: nil }])

    assert_nil timing[:started_at]
    assert_nil timing[:ended_at]
  end
end

describe 'the record of a finished session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - 3600)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - 600)
    DB[:workouts].where(id: @workout_id).update(finished_at: Time.now - 500)
    get "/workouts/#{@workout_id}/"
  end

  def times = last_response.body.scan(/<time data-local="(\d+)"/).flatten.map(&:to_i)

  it 'prints both ends' do
    assert_equal 2, times.length
  end

  it 'carries the instant rather than a rendered clock time, so the browser can place it' do
    assert_operator times.last, :>, times.first
  end

  # The machine-readable half, offset and all, so the page says what it means whether or not
  # any script runs.
  it 'carries a datetime with an offset on it' do
    assert_match(/datetime="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[-+]\d{2}:\d{2}"/, last_response.body)
  end

  # The fallback is the reading a browser with no JavaScript shows, and an unlabelled wrong
  # clock time is worse than an awkward right one -- there is no timezone anywhere in this app
  # yet (#349), so the server's own reading is UTC and says so.
  it 'labels the scriptless fallback as UTC rather than letting it read as local' do
    assert_match(%r{<time[^>]*>\d{2}:\d{2} UTC</time>}, last_response.body)
  end
end

# While a session is still running its finish has not happened yet, and the line above the
# times already says "so far" about it. A start printed alone under that reads as though the
# session were over.
describe 'the record of a session still under way' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - 3600)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - 600)
    get "/workouts/#{@workout_id}/"
  end

  it 'prints no ends at all' do
    refute_includes last_response.body, '<time data-local'
  end

  # The length is still reported, so this is an absence of the new line rather than of the
  # timing block it sits under.
  it 'still says how long it has been going' do
    assert_includes last_response.body, 'so far'
  end
end

describe 'the record of a session with nothing lifted in it' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  it 'prints no ends, because there is no training to put a time on' do
    account_id = login
    workout_id, exercise_id = scratch_workout(account_id)
    written_set(workout_id, exercise_id)
    get "/workouts/#{workout_id}/"

    refute_includes last_response.body, '<time data-local'
  end
end

# Workout 43 once read "-4275s active over 25m elapsed". A session marked finished before its
# last sets were ticked has a span that ends at the finish, and the long gap in front of those
# later sets was still being subtracted from it. Active time sits inside the span it is part of.
describe 'active time on a session finished before its last sets' do
  it 'is never negative, and never longer than the session' do
    start = Time.new(2026, 9, 16, 13, 27, 0)
    stamps = [start, start + 600, start + 1500, start + 7300, start + 7900] # a 97-minute gap, then two more
    timing = Tectonic::Timing.session({ finished_at: start + 1500 }, stamps.map { |at| { completed_at: at } })

    assert_equal 1500, timing[:overall]
    assert_operator timing[:active], :>=, 0
    assert_operator timing[:active], :<=, timing[:overall]
  end
end

