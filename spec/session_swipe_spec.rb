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

  # Scrolled to the panel's own left edge rather than to clientWidth * index. Those were
  # the same number while a panel was exactly one screen wide; #206 made them 88% of one so
  # that an edge of the next lift always shows, and the old arithmetic then landed between
  # two panels and let the snap decide which.
  def swipe_to(index)
    page.execute_script(<<~JS)
      (function () {
        var row = document.getElementById('lift-panels');
        var panel = row.querySelectorAll('section')[#{index}];
        row.scrollLeft = panel.offsetLeft - row.offsetLeft;
      })()
    JS
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

  # A panel was exactly one screen wide until #206, which is what left nothing at the edge
  # to say there was anything past it. It is 88% of one now, so a slice of the next lift is
  # always in view -- the cue both Nielsen Norman and Smashing name as the strong one, where
  # the dots this screen was relying on are the weak one.
  #
  # Asserted as a band rather than as a number: what matters is that a panel is most of the
  # screen and not all of it, and pinning 88% here would make this spec fail for a tweak to
  # the peek rather than for a panel that stopped peeking.
  it 'leaves an edge of the next lift showing' do
    row = page.evaluate_script("document.getElementById('lift-panels').clientWidth")
    boxes = page.evaluate_script(SwipedPanels::BOXES)

    assert_equal 3, boxes.length
    assert_equal 1, boxes.map(&:last).uniq.length, 'every panel should be the same width'
    width = boxes.first.last
    assert_operator width, :<, row, 'a panel that fills the screen hides the next one'
    assert_operator width, :>, row * 0.75, 'and one much narrower stops being a screen of lift'
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
  #
  # Scrolled to the foot of the page rather than to a fixed 300px. What is under test is
  # that the page scrolls vertically at all; how far is a property of how tall a session
  # happens to be, and pinning it made this spec fail for a reason that had nothing to do
  # with swiping -- #209 took the session rating form off the bottom, the page lost about
  # 150px, and a scroll to 300 clamped at 286.
  it 'leaves the page scrolling up and down as it did' do
    swipe_to(1)
    page.execute_script('window.scrollTo(0, document.body.scrollHeight)')

    assert_operator page.evaluate_script('window.scrollY'), :>, 0,
                    'the panels must not eat the page vertical scroll'
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

# The rating scale sat once at the bottom of the page, then once per panel, and is now a
# fixed footer. #277.
#
# The middle arrangement was the answer to panels: one copy at the foot of a long page was
# a swipe and a scroll away from the buttons it explains, so every panel that asked a
# rating question carried its own. Pinning it to the screen answers the same question
# better -- the foot of the viewport is nearer to every panel than the foot of one panel is
# to the others -- and the duplication has nothing left to buy.
describe 'where the rating scale sits' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeableSession

  before do
    get "/workouts/#{swipeable_session(login)}/session"
    @body = last_response.body
  end

  # Two lifts with working sets on them, and one scale. This counted two before #277, and
  # the number going down is the change: the copies were per panel, and there is now one
  # copy per page however many panels the session has.
  it 'is on the page exactly once, however many panels ask for a rating' do
    assert_equal 1, @body.scan('RPE Advice').length
  end

  # The old name, gone. Asserted rather than assumed, because a rename that leaves the old
  # string somewhere is a page with both on it, and the count above would not notice.
  it 'is not still asking the question it used to ask' do
    refute_includes @body, 'How do I rate this?'
  end

  # It used to be *inside* a panel, which is the arrangement this replaces. A copy left
  # behind in one would ride the swipe strip sideways and take its own guard with it.
  it 'is no longer inside any panel' do
    panels(@body).each { |panel| refute_includes panel, 'RPE Advice' }
  end

  # #175 is a picture of the foot of this page: the scale, the session rating buttons, and
  # the scale again. The scale belongs below the last panel now -- that is what a footer
  # is -- so what this holds is the half of #175 that is still a rule: the session rating
  # form is gone with #209, and one put back here would go unnoticed otherwise.
  it 'is below the last panel, and is the only thing there' do
    tail = @body.split('</section>').last

    assert_includes tail, 'RPE Advice'
    refute_includes tail, 'Session RPE'
  end
end

# What makes it a footer rather than simply the last thing on the page. #277 asks for the
# content to scroll *behind* it, which is a positioning claim and not a placement one.
describe 'the rating scale as page furniture' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeableSession

  before do
    get "/workouts/#{swipeable_session(login)}/session"
    @body = last_response.body
  end

  # Fixed, so the session scrolls behind it rather than ending above it.
  it 'is pinned to the foot of the screen rather than to the end of the content' do
    assert_includes @body, 'fixed inset-x-0 bottom-0'
  end

  it 'stays closed, because an open table would cover the session it explains' do
    refute_includes @body, '<details open'
  end

  # The footer is out of the flow, so nothing in the flow reserves space for it. Without
  # padding the last set row sits underneath it, and the control that ends up covered is
  # Done -- the one thing the screen is for.
  it 'leaves room beneath the last set row for itself' do
    assert_includes @body, 'mx-auto max-w-md pb-24'
  end
end

# A warmup is submaximal by definition and asks for no rating, which is why the ramp rows
# carry no RPE row and a warmup-only panel carries no scale. A session that is all ramp
# therefore has nothing on it the scale would be explaining, and renders none at all.
describe 'the rating scale on a session of nothing but warmups' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeableSession

  before do
    account_id = login
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    write_lift(workout_id, account_id, working: false)
    get "/workouts/#{workout_id}/session"
    @body = last_response.body
  end

  it 'is not on the page at all' do
    assert_equal 0, @body.scan('RPE Advice').length
  end

  # The page still renders, and still renders as a session rather than as an error, which
  # is the thing an assertion about something being absent can otherwise be passing on.
  it 'still draws the session it was asked for' do
    assert_equal 200, last_response.status
    assert_equal 1, panels(@body).length
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

