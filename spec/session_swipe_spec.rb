# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'session_spec'         # and its browser sign-up; also idempotent
require 'securerandom'

# The lifts of a session are a horizontal scroller a lifter swipes through, one lift a
# screen. None of that can be felt from here -- the suite has no thumb -- so what is
# asserted instead is the geometry a swipe produces and the state a swipe leaves behind:
# which panel sits under the middle of the scroller, and whether it is still there after
# htmx has replaced the whole of #session-body.
module SwipeableSession
  # `lifts` movements, the last of them a ramp and nothing else. A warmup-only lift asks
  # for no rating, which is what tells a panel that carries the rating scale from one
  # that has no business carrying it.
  def swipeable_session(account_id, lifts: 3)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    lifts.times { |position| write_lift(workout_id, account_id, working: position < lifts - 1) }
    workout_id
  end

  # A ramp and two working sets, which is a panel taller than a 500px-high viewport --
  # the point being that a panel owning the sideways scroll must not take the up-and-down
  # one with it.
  def write_lift(workout_id, account_id, working:)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, reps: 5, is_barbell: true, is_completed: false }
    2.times { |step| DB[:sets].insert(**common, weight: 95 + (step * 20), is_warmup: true) }
    2.times { DB[:sets].insert(**common, weight: 155, is_warmup: false) } if working
  end

  # The panels in source order. <section> is not nested on this screen, so splitting on
  # the opening tag is enough to hold one panel against another.
  def panels(body)
    body.split(/<section\b/)[1..].map { |panel| panel[%r{\A.*?</section>}m] }
  end
end

# Firefox will not go below a 500 CSS px viewport, and does not need to: Tailwind's `sm`
# breakpoint is 640px, so at 500 every unprefixed utility is in force and every `sm:`
# override is not, which is exactly the phone rule. The window is put back afterwards
# because one browser serves the whole suite and the specs run in a random order.
module SwipedPanels
  include SwipeableSession

  # Which panel sits under the middle of the scroller, which is the one a swipe stopped on.
  CENTRED = <<~JS
    (function () {
      var row = document.getElementById('lift-panels');
      var middle = row.getBoundingClientRect().left + (row.clientWidth / 2);
      return Array.prototype.findIndex.call(row.querySelectorAll('section'), function (panel) {
        var box = panel.getBoundingClientRect();
        return box.left <= middle && box.right > middle;
      });
    })()
  JS

  BOXES = <<~JS
    Array.prototype.map.call(document.querySelectorAll('#lift-panels > section'), function (panel) {
      var box = panel.getBoundingClientRect();
      return [Math.round(box.x + window.scrollX), Math.round(box.y + window.scrollY), Math.round(box.width)];
    })
  JS

  SIDEWAYS = 'document.documentElement.scrollWidth - document.documentElement.clientWidth'

  def open_session(width, height, lifts: 3)
    @restore = page.current_window.size
    page.current_window.resize_to(width, height)
    account_id = sign_up_for_session
    visit "/workouts/#{swipeable_session(account_id, lifts:)}/session"
  end

  def swipe_to(index)
    page.execute_script("var row = document.getElementById('lift-panels');" \
                        "row.scrollLeft = row.clientWidth * #{index};")
  end

  # Capybara waits on the DOM, and a snap scroller settles a frame or two after scrollLeft
  # is assigned, so this polls instead of trusting the first reading. It gives up and
  # returns whatever it last saw, so a failure reads as the wrong panel rather than as a
  # timeout that says nothing about which one.
  def settled_on(index)
    10.times do
      centred = page.evaluate_script(CENTRED)
      return centred if centred == index

      sleep 0.05
    end
    page.evaluate_script(CENTRED)
  end
end

describe 'the lifts of a session on a phone' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipedPanels

  before { open_session(500, 800) }
  after { page.current_window.resize_to(*@restore) }

  it 'gives each lift a panel exactly one screen wide' do
    row = page.evaluate_script("document.getElementById('lift-panels').clientWidth")
    boxes = page.evaluate_script(SwipedPanels::BOXES)

    assert_equal 3, boxes.length
    assert_equal [row] * 3, boxes.map(&:last)
  end

  # The trap nav.erb already documents: a flex child will not shrink below its content, so
  # a scroller is the easiest way there is to push a whole page sideways.
  it 'scrolls inside itself rather than taking the page with it' do
    assert_equal 0, page.evaluate_script(SwipedPanels::SIDEWAYS)
  end
end

describe 'swiping from one lift to the next' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipedPanels

  before { open_session(500, 800) }
  after { page.current_window.resize_to(*@restore) }

  it 'opens on the first lift and stops on whichever one it is swiped to' do
    assert_equal 0, settled_on(0)

    swipe_to(2)

    assert_equal 2, settled_on(2)
  end

  # A lift with a ramp and working sets is taller than a phone, so the panels may not eat
  # the vertical scroll on their way to owning the horizontal one.
  it 'leaves the page scrolling up and down as it did' do
    swipe_to(1)
    page.execute_script('window.scrollTo(0, 300)')

    assert_equal 300, page.evaluate_script('window.scrollY')
    assert_equal 1, settled_on(1), 'and scrolling down should not slide the panels sideways'
  end
end

# The one that matters. htmx replaces the whole of #session-body after every tap, and an
# innerHTML swap does not preserve scroll -- so without the listener in session.erb this
# lands back on lift one, on every set, for the whole session.
describe 'completing a set on a lift you swiped to' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipedPanels

  before { open_session(500, 800, lifts: 4) }
  after { page.current_window.resize_to(*@restore) }

  it 'leaves the lifter on that lift' do
    swipe_to(2)

    assert_equal 2, settled_on(2)

    within(all('#lift-panels > section')[2]) { first('button', text: 'Done').click }

    assert page.has_button?('Undo'), 'the tap should have completed a set'
    assert_equal 2, settled_on(2), 'the swap should not send the lifter back to the first lift'
  end
end

# 640px up is a mouse, and a mouse has no swipe: no horizontal wheel, and an overlay
# scrollbar that only appears once you are already scrolling. So the panels go back to
# being the stack they were, which is also what keeps the desktop page unchanged.
describe 'the same session on a desktop' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SwipedPanels

  before { open_session(1024, 900) }
  after { page.current_window.resize_to(*@restore) }

  it 'stacks the lifts down the page again' do
    boxes = page.evaluate_script(SwipedPanels::BOXES)
    tops = boxes.map { |box| box[1] }

    assert_equal 1, boxes.map(&:first).uniq.length, 'every lift should start at the same edge'
    assert_equal tops.sort, tops
    refute_equal tops[0], tops[1], 'and they should be one below another'
  end

  it 'still takes no width it was not given' do
    assert_equal 0, page.evaluate_script(SwipedPanels::SIDEWAYS)
  end
end

# The rating scale used to sit once at the bottom of the page. With the lifts as panels
# that is a swipe and a scroll away from the buttons it explains, so it is the footer of
# every panel that asks a rating question -- and of no panel that does not.
describe 'where the rating scale sits' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeableSession

  before do
    get "/workouts/#{swipeable_session(login)}/session"
    @body = last_response.body
  end

  # Two lifts with working sets on them, plus the session rating at the end of the page,
  # which is the same question about the whole session.
  it 'is under every question that asks for a rating' do
    assert_equal 3, @body.scan('How do I rate this?').length
  end

  it 'is not on a lift of nothing but warmups' do
    assert_includes panels(@body).first, 'How do I rate this?'
    refute_includes panels(@body).last, 'How do I rate this?'
  end

  it 'stays closed, because five open tables is worse than one far away' do
    refute_includes @body, '<details open'
  end
end

describe 'saying which lift you are on' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeableSession

  before do
    get "/workouts/#{swipeable_session(login)}/session"
    @body = last_response.body
  end

  # A swipe surface nobody knows is there is worse than the scroll it replaced.
  it 'numbers each panel and says how many there are' do
    assert_includes panels(@body).first, '1 of 3'
    assert_includes panels(@body).last, '3 of 3'
  end

  # The progress bar covers the whole session and is the one thing that says how much is
  # left of it, so it stays outside the panels and stays whole.
  it 'keeps the session-wide progress bar out of the panels' do
    assert_includes @body, '0 of 10 sets'
    refute_includes panels(@body).first, '0 of 10 sets'
  end
end

