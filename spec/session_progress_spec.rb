# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What the bar at the top of a session counts. It used to draw one dash per set, which on
# a five-movement session of six sets each is thirty segments twelve pixels wide on a
# phone -- and it disagreed with the panel immediately below it, which says "1 of 5" over
# five dots. It now draws one segment per lift and fills each with that lift's own sets.
#
# Read off the rendered markup, because none of this fails anything on its own: the page
# renders either way and every button on it works. The only symptom is a bar that answers
# a different question from the one underneath it.
module SessionProgress
  # The bar runs from its own label to the line of text under it, which is the next thing
  # in the template. Anchored on both ends so a segment count can never quietly pick up
  # markup from the panels below.
  def progress_bar(body) = body[/aria-label="Session progress"(.*?)<p class="mt-1/m, 1].to_s

  # One chunk per lift. The track is the only element carrying the resting grey, so
  # splitting on it cuts the bar exactly at the lift boundaries.
  def segments(body) = progress_bar(body).split('rounded-sm bg-gray-300"')[1..].to_a

  # A slice is one set. The trailing closing tags in the final chunk carry no class, so
  # they cannot be counted as one.
  def slices(segment) = segment.scan(/class="flex-1[^"]*"/)

  def filled(segment) = segment.scan('class="flex-1 bg-lime-500"')

  # Three lifts of deliberately different lengths, so a spec cannot pass by counting the
  # wrong thing and getting the right number: 2, 3 and 2 sets, with 2, 1 and 0 of them
  # done. Seven sets, three complete, three lifts -- no two of which are equal.
  SHAPE = [{ sets: 2, done: 2 }, { sets: 3, done: 1 }, { sets: 2, done: 0 }].freeze

  def session_of_uneven_lifts(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    SHAPE.each do |lift|
      exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
      lift[:sets].times do |set|
        DB[:sets].insert(workout_id:, exercise_id:, weight: 135, reps: 5, is_barbell: true,
                         is_warmup: false, is_completed: set < lift[:done])
      end
    end
    workout_id
  end
end

describe 'the bar at the top of a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionProgress

  before do
    get "/workouts/#{session_of_uneven_lifts(login)}/session"
    @body = last_response.body
  end

  it 'draws one segment per lift rather than one per set' do
    assert_equal SessionProgress::SHAPE.length, segments(@body).length
  end

  # The count the old bar drew. Asserted as the number it must not be, because three
  # segments and seven segments are both plausible-looking bars in a screenshot.
  it 'does not draw one per set' do
    refute_equal 7, segments(@body).length
  end

  # The bar answers "how many movements" now, so the exact set count has nowhere else to
  # live and has to stay on the line underneath.
  it 'still says how many sets are done in words' do
    assert_includes @body, '3 of 7 sets'
  end
end

describe 'how a segment of the session bar fills' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionProgress

  before do
    get "/workouts/#{session_of_uneven_lifts(login)}/session"
    @body = last_response.body
  end

  it 'carries one slice per set of its own lift' do
    assert_equal(SessionProgress::SHAPE.map { |lift| lift[:sets] },
                 segments(@body).map { |segment| slices(segment).length })
  end

  it 'paints as many of them as that lift has finished' do
    assert_equal(SessionProgress::SHAPE.map { |lift| lift[:done] },
                 segments(@body).map { |segment| filled(segment).length })
  end

  # The whole of what a part-filled segment buys over one that flips whole. The middle
  # lift is one set into three: an all-or-nothing bar draws it the same as the untouched
  # lift beside it, and this is the assertion that would catch that.
  it 'draws a lift underway as neither finished nor untouched' do
    underway = segments(@body)[1]

    refute_equal 0, filled(underway).length, 'a lift with a set done should not read as untouched'
    refute_equal slices(underway).length, filled(underway).length, 'nor should it read as finished'
  end
end

