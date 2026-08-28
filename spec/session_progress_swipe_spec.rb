# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'session_swipe_spec' # reuses its swipeable session and panel geometry

# #212: the session progress bar did not move when you swiped.
#
# It could not. The bar is rendered from what has been completed, and swiping completes
# nothing, so it sat perfectly still above a screen that had just changed -- which reads as
# a bar that has stopped working rather than as one answering a different question.
#
# It now marks the segment belonging to the lift on screen, so the one bar says both how
# much of the session is done and where in it you are. Driven in a real browser because the
# mark comes off a scroll position, and a scroll position is the one thing a Rack::Test
# spec has no way to have.
module SwipeMarks
  include SwipedPanels

  # The segments marked current, by their lift index. A list rather than a single index
  # because more than one would mean the bar is claiming you are in two places.
  MARKED = <<~JS
    Array.prototype.filter.call(
      document.querySelectorAll('[data-lift-segment]'),
      function (segment) { return segment.getAttribute('data-current') === 'true'; }
    ).map(function (segment) { return Number(segment.getAttribute('data-lift-segment')); })
  JS

  def marked
    page.evaluate_script(MARKED)
  end

  # Polls for the same reason settled_on does: a snap scroller settles a frame or two after
  # scrollLeft is assigned, and the mark follows the scroll rather than leading it.
  def marked_after(index)
    swipe_to(index)
    10.times do
      return marked if marked == [index]

      sleep 0.05
    end
    marked
  end
end

describe 'the session progress bar while swiping' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipeMarks

  before { open_session(500, 800) }
  after { page.current_window.resize_to(*@restore) }

  it 'marks the first lift before anything is swiped' do
    assert_equal [0], marked
  end

  it 'follows the swipe from one lift to the next' do
    assert_equal [1], marked_after(1)
    assert_equal [2], marked_after(2)
    assert_equal [0], marked_after(0)
  end

  # The whole reason the offset restore below it exists: htmx replaces #session-body on
  # every tap, which takes the bar and its marks with it. A mark that did not come back
  # would leave the bar blank from the first completed set onwards -- worse than never
  # having marked it, because it would look broken rather than absent.
  it 'still marks the lift after htmx has replaced the body' do
    assert_equal [1], marked_after(1)

    within(all('#lift-panels > section')[1]) { first(:button, 'Done').click }

    assert_equal 1, settled_on(1), 'the swipe should survive the swap'
    assert_equal [1], marked, 'and so should the mark on the bar'
  end
end

# Six lifts, because the arithmetic this catches is right for the first few and wrong after.
# The script divided the scroll offset by the *scroller's* width, which was the panel's
# width until #206 made a panel 88% of it so the next lift peeks. Dividing by the wrong one
# drifts 12% a lift: correct through the fourth, and from the fifth on it marks the lift
# behind the one you are looking at. Three panels could never show it, which is why the
# session here is longer than any other spec's.
describe 'the progress bar on a session long enough for the drift to show' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipeMarks

  before { open_session(500, 800, lifts: 6) }
  after { page.current_window.resize_to(*@restore) }

  it 'marks the lift you are on, all the way to the last' do
    (0..5).each { |lift| assert_equal [lift], marked_after(lift), "lift #{lift}" }
  end
end

