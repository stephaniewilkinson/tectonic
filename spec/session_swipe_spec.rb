# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses login and token_from; idempotent require
require 'securerandom'

# A session shaped like a real training day, because the two things under test only show
# up in one: five lifts, so there is something to swipe between; ramps of different
# lengths, so the panels are different heights and one of them is taller than a phone;
# and a lift that is all warmups, since that is the panel the RPE help must stay off.
module SwipeSession
  LIFTS = [
    { name: 'Back Squat', warmups: [45, 95, 135, 155], working: [185, 185, 185] },
    { name: 'Bench Press', warmups: [45, 75], working: [135, 135, 135] },
    { name: 'Deadlift', warmups: [135, 185], working: [275, 275, 275] },
    { name: 'Barbell Row', warmups: [45, 65, 95], working: [] },
    { name: 'Overhead Press', warmups: [45], working: [95, 95] }
  ].freeze

  # Inserted rather than typed in: a ramp is generated, and no form in the app writes one.
  def seed_session(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    LIFTS.each { |lift| seed_lift(workout_id, account_id, lift) }
    workout_id
  end

  def seed_lift(workout_id, account_id, lift)
    exercise_id = DB[:exercises].insert(name: "#{lift[:name]} #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, reps: 5, is_barbell: true, is_completed: false }
    lift[:warmups].each { |weight| DB[:sets].insert(**common, weight:, is_warmup: true) }
    lift[:working].each { |weight| DB[:sets].insert(**common, weight:, is_warmup: false) }
  end
end

describe 'a session rendered as panels' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeSession

  before do
    account_id = login
    get "/workouts/#{seed_session(account_id)}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # One panel per lift, each a full screen wide and snapping to the middle of the strip.
  # shrink-0 is the load-bearing one: a flex row squeezes its children by default, and
  # without it five lifts share one screen instead of taking one each.
  it 'gives every lift a panel of its own' do
    assert_equal 5, @body.scan(/<section id="lift-\d+" class="[^"]*\bsnap-center\b/).length
    assert_equal 5, @body.scan(/<section id="lift-\d+" class="[^"]*\bw-full shrink-0\b/).length
  end

  # A swipe surface with nothing to say it is one is worse than the scroll it replaced.
  it 'says which lift of how many each panel is' do
    (1..5).each { |number| assert_includes @body, "#{number} of 5" }
  end

  # Links, so the panels are reachable by tap and by keyboard and not only by gesture,
  # and each says out loud which lift it goes to rather than being an unnamed dot.
  it 'offers a dot per lift that goes to that lift' do
    assert_equal (1..5).map { |number| "#lift-#{number}" }, @body.scan(/href="(#lift-\d+)"/).flatten
    assert_equal 5, @body.scan(/class="sr-only">\s*\S[^<]*, lift \d of 5/).length
  end

  # The progress bar covers the whole session and is the only thing that says how much is
  # left overall, so it stays outside the strip where a swipe cannot take it away.
  it 'leaves the whole-session progress bar above the strip' do
    assert_operator @body.index('Session progress'), :<, @body.index('id="lift-strip"')
    assert_includes @body, '0 of 23 sets'
  end
end

describe 'the RPE help under each lift' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwipeSession

  before do
    account_id = login
    get "/workouts/#{seed_session(account_id)}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  def panel(number)
    @body[%r{<section id="lift-#{number}".*?</section>}m]
  end

  # Four lifts ask for a rating and so carry the table; the session's own rating asks the
  # same question at the foot of the page and keeps a copy there.
  it 'follows the lifts that ask for a rating' do
    assert_equal 5, @body.scan('How do I rate this?').length
    [1, 2, 3, 5].each { |number| assert_includes panel(number), 'How do I rate this?' }
  end

  # Barbell Row is all warmups, which means it has no RPE row at all -- so help on how to
  # rate would be help with a question this panel never asks.
  it 'stays off a lift that is all warmups' do
    refute_includes panel(4), 'name="rpe"'
    refute_includes panel(4), 'How do I rate this?'
  end

  # Five copies in the DOM, one in the source. Closed, so five of them cost a summary
  # line each rather than five open tables.
  it 'is one partial and starts closed' do
    refute_includes @body, '<details class="mt-4 border-t border-gray-300 pt-3" open'
    assert_equal 5, @body.scan('The most reliable observable is bar speed').length
  end
end

# The suite cannot feel a swipe, so it measures one: the strip is scrolled the way a
# thumb would scroll it and the panel that ends up against the left edge is asserted.
# 500px because Firefox will not give a narrower viewport, and Tailwind's sm: breakpoint
# is 640px, so 500 is on the phone side of every rule this change adds.
module SwipeBrowser
  include SwipeSession

  def sign_up
    email = "#{SecureRandom.hex}@gmail.com"
    password = SecureRandom.hex
    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: email
    fill_in 'email-confirm', with: email
    fill_in 'password', with: password
    fill_in 'password-confirm', with: password
    click_on 'Sign up'
    DB[:accounts].where(email:).get(:id)
  end

  def open_session(width: 500)
    page.driver.browser.manage.window.resize_to(width, 900)
    visit "/workouts/#{seed_session(sign_up)}/session"
  end

  # How far the panel's left edge sits from the strip's, which is zero for exactly the
  # panel currently filling the strip.
  def panel_offset(number)
    page.evaluate_script(<<~JS)
      Math.round(document.getElementById('lift-#{number}').getBoundingClientRect().x -
                 document.getElementById('lift-strip').getBoundingClientRect().x)
    JS
  end

  def swipe_to(number)
    page.execute_script(<<~JS)
      const strip = document.getElementById('lift-strip');
      strip.scrollLeft = #{number - 1} * strip.clientWidth;
    JS
  end
end

describe 'swiping the strip on a phone' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include SwipeBrowser

  before { open_session }

  it 'starts on the first lift and lands on the one it is scrolled to' do
    assert_equal 0, panel_offset(1)

    swipe_to(3)

    assert_equal 0, panel_offset(3)
    assert_operator page.evaluate_script("document.getElementById('lift-strip').scrollLeft"), :>, 0
  end

  # A horizontal scroller is the easiest way to push a whole page sideways: a flex child
  # will not shrink below its content, the trap views/nav.erb documents. The strip is a
  # block child, so the panels are 100% of it and the overflow stays inside it.
  it 'does not take the page sideways with it' do
    swipe_to(3)

    assert_equal page.evaluate_script('document.documentElement.clientWidth'),
                 page.evaluate_script('document.documentElement.scrollWidth')
  end

  # A squat with a four-step ramp is taller than a phone. The strip has an automatic
  # height, so that height belongs to the page and the page scrolls as it always did.
  it 'still scrolls down inside a lift that is taller than the screen' do
    page.execute_script('window.scrollTo(0, 400)')

    assert_operator page.evaluate_script('window.scrollY'), :>, 0
    assert_equal 0, panel_offset(1)
  end

  # The panels are in document order and nothing is hidden, so tabbing walks the session
  # lift by lift the way the stacked list did -- and the strip follows, because a browser
  # scrolls a focused control into view. Somebody on a keyboard gets the swipe for free.
  it 'brings a panel into view when something inside it takes focus' do
    page.execute_script("document.querySelector('#lift-4 button').focus()")

    assert_equal 0, panel_offset(4)
  end
end

# The one that matters. htmx swaps the whole of #session-body after every tap, and an
# innerHTML swap empties the element first, which drops a scroll container to zero. Left
# alone, finishing a set on the third lift would put the lifter back on the first.
describe 'completing a set on the third lift' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include SwipeBrowser

  before do
    open_session
    swipe_to(3)
  end

  it 'leaves the lifter on the third lift' do
    within('#lift-3') { all('button', text: 'Done').last.click }

    assert page.has_button?('Undo'), 'the set should come back done'
    assert_equal 0, panel_offset(3)
  end

  # Rating is the other way a set is completed, and it swaps the same body.
  it 'stays put when the set is rated rather than tapped done' do
    within('#lift-3') { first('button', text: '8').click }

    assert page.has_button?('Undo'), 'rating a set completes it'
    assert_equal 0, panel_offset(3)
  end
end

# From 640px up the strip is a plain block again and the lifts stack as they always did:
# a swipe is a thumb gesture, a wheel does nothing to a horizontal scroller, and vertical
# room is the thing a desktop has and a phone does not.
describe 'the same session on a desktop' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include SwipeBrowser

  before { open_session(width: 1024) }

  it 'stacks the lifts instead of putting them side by side' do
    assert_equal 0, panel_offset(1)
    assert_equal 0, panel_offset(5)
    assert_operator page.evaluate_script("document.getElementById('lift-5').getBoundingClientRect().y"),
                    :>, page.evaluate_script("document.getElementById('lift-1').getBoundingClientRect().y")
  end

  it 'has no strip to scroll sideways' do
    assert_equal 0, page.evaluate_script("document.getElementById('lift-strip').scrollWidth -
                                          document.getElementById('lift-strip').clientWidth")
    assert_equal page.evaluate_script('document.documentElement.clientWidth'),
                 page.evaluate_script('document.documentElement.scrollWidth')
  end
end

