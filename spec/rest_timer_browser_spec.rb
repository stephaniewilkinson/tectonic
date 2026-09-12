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

  # The same, with the working set carrying the rest its block prescribed -- which is what the
  # generator writes onto a lift with a rest_seconds on it.
  def session_prescribing(seconds)
    account_id = sign_up_for_session
    workout_id, = generated_session(account_id)
    DB[:sets].where(workout_id:, is_warmup: false).update(planned_rest_seconds: seconds)
    visit "/workouts/#{workout_id}/session"
    workout_id
  end

  def suggestion_text = find('[data-rest-start="suggested"]', visible: :all).text

  def timer = find('#rest-timer', visible: :all)

  def clock_text = find('[data-rest-clock]', visible: :all).text

  # Capybara's waiting matchers are what keep these from being sleeps: the assertion blocks
  # until htmx has swapped the panel in and the script has read the cue.
  def finish_a_set
    first('button', text: 'Done').click
    assert has_css?('#rest-timer', visible: true, wait: 5)
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

  # #395. The clock runs from the Done tap, because the rest began when the set ended. This
  # replaces an assertion that it did *not* start until a duration was tapped -- that rule was
  # about the bell and was wrongly applied to the clock, which cost a lifter the number they
  # most want between sets and made them ask for it every set.
  it 'starts counting the moment a set is finished' do
    finish_a_set

    assert_equal '0:00', clock_text
    sleep 2.5

    assert_operator seconds_in(clock_text), :>, 0
  end
end

# Counting is not counting down. Nothing is going to happen at any particular number until
# somebody names one, so the durations stay on offer and the clock stays silent.
describe 'the rest timer before a length is chosen' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  it 'keeps the durations on offer while nothing has been asked for' do
    finish_a_set

    assert has_css?('#rest-timer [data-rest-offer]', visible: true)
    refute has_css?('#rest-timer [data-rest-steps]', visible: true)
  end

  it 'turns into a countdown on a tap and shows the time it was given' do
    start_a_rest_of '1:00'

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_operator seconds_in(clock_text), :<=, 60
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

# What the timer defaults to, on the screen. The number and the word have to agree: a median
# shown under "prescribed" would be the app passing its own measurement off as the programme's
# instruction, and the reverse would disown an instruction somebody wrote.
describe 'the rest the programme prescribed' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  # The one length the timer counts down to without being asked. #395 says the bell needs a
  # length somebody gave it, and a block writing five minutes between singles is a person
  # giving one -- so this needs no second tap, where the measured median does.
  def finish_the_working_set
    # The first Done on this screen is the warmup rung, which carries no prescription, so the
    # working set is the one to tap.
    all('button', text: 'Done').last.click
    assert has_css?('#rest-timer', visible: true, wait: 5)
  end

  it 'counts down from the prescribed length with no second tap' do
    session_prescribing(300)
    finish_the_working_set

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_operator seconds_in(clock_text), :<=, 300
    assert_operator seconds_in(clock_text), :>, 290
  end

  # It starts on its own, so its button is never seen -- and without the word beside the clock
  # a lifter would watch a countdown with nothing saying whether the block asked for it or the
  # app worked it out.
  it 'says whose number it is counting, beside the clock' do
    session_prescribing(300)
    finish_the_working_set

    assert_equal 'prescribed', find('[data-rest-source]').text
  end
end

# A ramp rung prescribes nothing -- three minutes between heavy singles is not three minutes
# between the 95lb and 135lb rungs -- so tapping one counts up and rings at nothing, exactly
# as a session with no block at all does.
describe 'a warmup rung under a block that prescribes a rest' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  it 'is left counting up, with the durations still on offer' do
    session_prescribing(300)
    first('button', text: 'Done').click

    assert has_css?('#rest-timer [data-rest-offer]', visible: true, wait: 5)
    refute has_css?('#rest-timer [data-rest-steps]', visible: true)
    refute_includes suggestion_text, 'prescribed'
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

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_operator seconds_in(clock_text), :<, before
  end
end

