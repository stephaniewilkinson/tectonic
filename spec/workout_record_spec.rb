# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The record of a workout, as distinct from the session screen that logs one. Two of its
# columns are headed with a question -- "Warmup?", "Completed?" -- and a question is
# answered here by a box that is ticked or left empty. Which box belongs to which
# question is the whole of what can go wrong with two adjacent columns that look alike,
# so that is what these assert rather than the mere presence of a glyph.
module WorkoutRecord
  TICKED = '&#9745;'
  EMPTY = '&#9744;'

  def app
    Tectonic.app
  end

  def log_set(is_warmup:, is_completed:)
    DB[:sets].insert(workout_id: @workout_id, exercise_id: @exercise_id, weight: 100, reps: 5,
                     is_warmup:, is_completed:)
  end

  # The row a set is drawn in. Split rather than matched across the row, because a
  # regular expression that has to stop at the first </tr> is harder to read than this
  # is, and the href is unique to the set.
  def row_for(set_id)
    last_response.body.split('<tr>').find { |chunk| chunk.include?(%(/sets/#{set_id}")) }
  end

  def boxes_in(row)
    row.scan(/#{TICKED}|#{EMPTY}/)
  end
end

describe 'the boolean columns of a workout record' do
  include Rack::Test::Methods
  include RouteOwnership
  include WorkoutRecord

  before do
    account_id = login
    @workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    @exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
  end

  it 'ticks the box of the fact that is true and leaves the other empty' do
    warmup = log_set(is_warmup: true, is_completed: false)
    lifted = log_set(is_warmup: false, is_completed: true)

    get "/workouts/#{@workout_id}"

    assert_equal [WorkoutRecord::TICKED, WorkoutRecord::EMPTY], boxes_in(row_for(warmup))
    assert_equal [WorkoutRecord::EMPTY, WorkoutRecord::TICKED], boxes_in(row_for(lifted))
  end

  # The words these replaced were the bug: "Warmup set" and "No" are answers to two
  # different questions, and "Incomplete" is a word where its opposite was a glyph.
  it 'answers with a box rather than a word' do
    log_set(is_warmup: true, is_completed: false)

    get "/workouts/#{@workout_id}"

    refute_includes last_response.body, 'Warmup set'
    refute_includes last_response.body, 'Incomplete'
  end
end

# A box says nothing when it is read aloud, and an empty one says nothing at all, so the
# answer is spelled out beside it for a reader that cannot see the column.
describe 'a workout record read aloud' do
  include Rack::Test::Methods
  include RouteOwnership
  include WorkoutRecord

  it 'spells both answers out for a screen reader' do
    account_id = login
    @workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    @exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    log_set(is_warmup: true, is_completed: false)

    get "/workouts/#{@workout_id}"

    assert_includes last_response.body, '<span class="sr-only">warmup</span>'
    assert_includes last_response.body, '<span class="sr-only">not completed</span>'
  end
end

