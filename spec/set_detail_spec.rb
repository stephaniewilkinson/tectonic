# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The page a lifter reaches by opening one set. Its two booleans read `Yes` / `No` while
# the list they were opened from and the workout record beside it answered the same two
# with a box. What these pin is the box: a definition list saying "Warmup: Yes" reads as
# a sentence, and that sentence is what was given up for one spelling across the three
# screens that show the fact.
module SetDetail
  TICKED = '&#9745;'
  EMPTY = '&#9744;'

  # A signed-in account's own set, opened on its own page.
  def detail(is_warmup: false, is_completed: false)
    account_id = login
    workout = own_workout(account_id)
    exercise = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    set = DB[:sets].insert(workout_id: workout, exercise_id: exercise, weight: 135, reps: 5,
                           is_warmup:, is_completed:)
    get "/workouts/#{workout}/sets/#{set}"
    last_response.body
  end

  # Both boxes in the order the rows stand in, which is what says a box belongs to the
  # term above it rather than to the other one.
  def boxes(body)
    body.scan(/#{TICKED}|#{EMPTY}/)
  end
end

describe 'how a set detail answers Warmup and Completed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetDetail

  it 'ticks the box of the fact that is true and leaves the other empty' do
    assert_equal [SetDetail::TICKED, SetDetail::EMPTY], boxes(detail(is_warmup: true))
    assert_equal [SetDetail::EMPTY, SetDetail::TICKED], boxes(detail(is_completed: true))
  end

  it 'answers with a box rather than with a word' do
    body = detail(is_warmup: true)

    refute_includes body, '>Yes<'
    refute_includes body, '>No<'
  end

  # A box says nothing read aloud, and an empty one says nothing twice over, so the
  # answer is spelled out beside it in the words of the term it answers.
  it 'spells both answers out for a screen reader' do
    body = detail(is_warmup: true)

    assert_includes body, '<span class="sr-only">warmup</span>'
    assert_includes body, '<span class="sr-only">not completed</span>'
  end
end

