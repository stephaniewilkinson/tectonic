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

  # The word beside the clock, which is where the length and the overshoot moved when #514
  # stopped the clock changing direction. "/ 3:00" while the bell is ahead, "+0:42" once it
  # has gone.
  def bell_text = find('[data-rest-bell]', visible: :all).text

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

  # A MM:SS reading as a number of seconds, so the direction of travel can be asserted rather
  # than the text compared. It used to return a signed number, because the clock ran backwards
  # and then forwards through zero and the sign was how a spec could tell which side of the
  # rest it was reading. #514 left one direction, so there is one sign; the glyph the bell's
  # word wears is asserted where it is the point, and stripped here where it is not.
  def seconds_in(text)
    minutes, seconds = text.gsub(%r{[+/]}, '').strip.split(':').map(&:to_i)
    (minutes * 60) + seconds
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

# Counting is not counting down, and after #514 it is never counting down. Nothing is going to
# happen at any particular number until somebody names one, so the durations stay on offer and
# the clock stays silent -- and when somebody does name one, the clock goes on exactly as it
# was and the bar grows a bell.
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

  it 'says nothing beside the clock while there is no bell to say anything about' do
    finish_a_set

    refute has_css?('#rest-timer [data-rest-bell]', visible: true)
  end

  # #514. A tapped duration used to turn the display into a countdown; now it sets a bell and
  # the clock carries on climbing. This is the branch the decision explicitly extended to --
  # the offer was stopwatch-by-default-countdown-if-you-tap, and it was turned down.
  it 'sets a bell on a tap and leaves the clock climbing' do
    start_a_rest_of '1:00'

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_operator seconds_in(clock_text), :<, 5
    assert_equal 60, seconds_in(bell_text)
  end

  # The length has to be readable, or a climbing number is a stopwatch with a secret: the
  # lifter tapped 1:00 and has no way back to which of the four it was.
  it 'says the length it is going to ring at' do
    start_a_rest_of '2:00'

    assert_match(%r{\A/}, bell_text)
    assert_equal 120, seconds_in(bell_text)
  end
end

# That it is a clock and not a picture of one. These read the number off the screen twice
# with a real gap between, which is the only assertion that says it ticks.
describe 'the rest timer counting' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  it 'actually counts, and it counts upward' do
    start_a_rest_of '5:00'
    first = clock_text
    sleep 2.5

    refute_equal first, clock_text, 'the clock never moved'
    assert_operator seconds_in(clock_text), :>, seconds_in(first)
  end

  # The bell is a moment, not a countdown, so the number beside the clock holds still while
  # the clock climbs towards it.
  it 'holds the bell still while the clock climbs' do
    start_a_rest_of '5:00'
    named = bell_text
    sleep 2.5

    assert_equal named, bell_text
  end

  # Past the bell it goes on counting rather than stopping, which is the half that keeps it
  # honest: a timer that stops at the bell implies the rest ended there, when what happened is
  # that you took another forty seconds. The overshoot is the bell's word now, because a
  # climbing number with a grey tint on it does not say "that has gone" on its own.
  it 'says the bell has gone, and goes on counting' do
    start_a_rest_of '1:00'
    # Wound down to a second out rather than waited out, so the spec costs two seconds and
    # not sixty. The step buttons are the same path a lifter uses.
    2.times { find('[data-rest-step="-30"]').click }
    sleep 2

    assert_match(/\A\+/, bell_text)
    assert_operator seconds_in(clock_text), :>, 0
  end
end

describe 'the rest timer under a thumb' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  # The steps wind the bell, not the clock. Nothing on this bar can take thirty seconds off
  # the rest you have actually had, which is what the clock reads -- so these assert the bell
  # moved and, in the first one, that the clock did not.
  it 'rings thirty seconds sooner when asked' do
    start_a_rest_of '5:00'
    standing = seconds_in(clock_text)
    find('[data-rest-step="-30"]').click

    assert_equal 270, seconds_in(bell_text)
    assert_operator seconds_in(clock_text), :>=, standing
  end

  it 'rings thirty seconds later when asked' do
    start_a_rest_of '1:00'
    find('[data-rest-step="30"]').click

    assert_equal 90, seconds_in(bell_text)
  end

  it 'goes away when dismissed' do
    start_a_rest_of '2:00'
    find('[data-rest-dismiss]').click

    refute timer.visible?
  end
end

describe 'a bell wound back and forth past the clock' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestingBrowser

  before { session_with_a_set }

  # Winding back up past the elapsed time is a rest that is running again, so the bell
  # re-arms -- and the word beside the clock goes back from an overshoot to a length at the
  # same moment, which is the visible half of it. Before #514 the same fact showed up as the
  # clock changing direction, which is the behaviour that is gone.
  it 'goes back to naming a length once it is ahead of the clock again' do
    start_a_rest_of '1:00'
    2.times { find('[data-rest-step="-30"]').click }

    assert_match(/\A\+/, bell_text)

    find('[data-rest-step="30"]').click

    assert_match(%r{\A/}, bell_text)
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

  it 'sets the bell at the prescribed length with no second tap' do
    session_prescribing(300)
    finish_the_working_set

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_equal 300, seconds_in(bell_text)
  end

  # The whole of #514, in the one place it was most wrong. A movement carrying a prescribed
  # rest used to open the bar at 3:00 falling, on every single set, so the stopwatch #395 was
  # reopened to provide was the one thing a lifter on a written programme never saw. The
  # prescription is still honoured -- it is a bell at 5:00 rather than a clock that starts
  # there.
  it 'still starts the clock at nothing and climbs' do
    session_prescribing(300)
    finish_the_working_set

    assert_operator seconds_in(clock_text), :<, 5
    sleep 2.5

    assert_operator seconds_in(clock_text), :>, 0
  end

  # It arms on its own, so its button is never seen -- and without the word beside the clock a
  # lifter would watch a bell with nothing saying whether the block asked for that length or
  # they tapped it themselves.
  it 'says whose number it is ringing at, beside the clock' do
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
    assert_operator seconds_in(clock_text), :>, before
    assert_equal 300, seconds_in(bell_text), 'the poll moved the bell'
  end
end

