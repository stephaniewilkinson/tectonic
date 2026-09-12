# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'session_spec' # reuses its browser sign-up and generated_session
require 'securerandom'

# The half of the rest timer that only a browser can answer. #281.
#
# spec/rest_timer_spec.rb pins what the server sends -- the cue, the suggestion, when there
# is and is not one. None of that is a timer. A countdown that arms but never counts, or
# counts but never reaches zero, or restarts itself every time the fifteen-second poll swaps
# a panel, passes every assertion over there and is useless in a gym. So these drive a real
# Firefox and read the number off the screen.
#
# The precedent is #281's own session clock, which was verified the same way and for the same
# reason: "75s to 78s over three seconds" is the only assertion that actually says it ticks.
module RestingBrowser
  include Capybara::DSL

  # A session with one working set, arrived at through the forms. The timer arms off a Done
  # tap, so the set has to be tappable.
  def session_with_a_set
    account_id = sign_up_for_session
    workout_id, = generated_session(account_id)
    visit "/workouts/#{workout_id}/session"
    workout_id
  end

  def timer = find('#rest-timer', visible: :all)

  def clock_text = find('[data-rest-clock]', visible: :all).text

  # Capybara's waiting matchers are what keep these from being sleeps: the assertion blocks
  # until htmx has swapped the panel in and the script has read the cue.
  def finish_a_set
    first('button', text: 'Done').click
    assert has_css?('#rest-timer [data-rest-offer]', visible: true, wait: 5)
  end

  def start_a_rest_of(label)
    finish_a_set
    click_button label
  end

  # The clock as a signed number of seconds, so a count past zero reads as negative and the
  # direction of travel can be asserted rather than the text compared.
  def seconds_in(text)
    sign = text.start_with?('+') ? -1 : 1
    minutes, seconds = text.delete('+').split(':').map(&:to_i)
    sign * ((minutes * 60) + seconds)
  end
end

describe 'the rest timer arming' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  # Nothing until a set is finished, which is the whole of its trigger.
  it 'is out of the way until a set is finished' do
    refute timer.visible?
  end

  it 'offers a countdown once a set is done' do
    finish_a_set

    assert timer.visible?
  end

  # The offer is an offer. Arming must not start anything, because a lifter who taps Done and
  # walks off should not be beeped at by a countdown they never asked for.
  it 'does not start itself' do
    finish_a_set

    refute has_css?('#rest-timer [data-rest-running]', visible: true)
  end

  it 'starts on a tap and shows the time it was given' do
    start_a_rest_of '1:00'

    assert_equal '1:00', clock_text
  end
end

# That it is a clock and not a picture of one. These read the number off the screen twice
# with a real gap between, which is the only assertion that says it ticks.
describe 'the rest timer counting' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  it 'actually counts down' do
    start_a_rest_of '5:00'
    first = clock_text
    sleep 2.5

    refute_equal first, clock_text, 'the countdown never moved'
    assert_operator seconds_in(clock_text), :<, seconds_in(first)
  end

  # Past zero it counts up rather than stopping, which is the half that keeps it honest: a
  # timer that stops at 0:00 implies the rest ended there, when what happened is that you
  # took another forty seconds.
  it 'counts up past zero rather than stopping' do
    start_a_rest_of '1:00'
    # Wound down to a second out rather than waited out, so the spec costs two seconds and
    # not sixty. The step buttons are the same path a lifter uses.
    2.times { find('[data-rest-step="-30"]').click }
    sleep 2

    assert_match(/\A\+/, clock_text)
  end
end

describe 'the rest timer under a thumb' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  it 'takes thirty seconds off when asked' do
    start_a_rest_of '5:00'
    find('[data-rest-step="-30"]').click

    assert_operator seconds_in(clock_text), :<=, 271
  end

  it 'adds thirty seconds when asked' do
    start_a_rest_of '1:00'
    find('[data-rest-step="30"]').click

    assert_operator seconds_in(clock_text), :>, 60
  end

  it 'goes away when dismissed' do
    start_a_rest_of '2:00'
    find('[data-rest-dismiss]').click

    refute timer.visible?
  end
end

# The reason the whole thing lives outside #session-body. The poll swaps every panel every
# fifteen seconds; a countdown inside that region would restart four times a minute.
describe 'the rest timer against the poll' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  # The swap is forced rather than waited for, so the spec costs two seconds and not fifteen.
  it 'survives the session being swapped out from under it' do
    start_a_rest_of '5:00'
    before = seconds_in(clock_text)
    page.execute_script("htmx.trigger(document.getElementById('session-poll'), 'load')")
    sleep 2

    assert has_css?('#rest-timer [data-rest-running]', visible: true)
    assert_operator seconds_in(clock_text), :<, before
  end
end

