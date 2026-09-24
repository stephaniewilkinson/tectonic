# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'losing_signal_browser_spec' # reuses the fog: an unreachable host, and the
require_relative 'rest_timer_browser_spec'    # rewrite that points the page at it
require 'securerandom'

# The rest timer starting without the server. #513.
#
# The ticket reads "clicking done is supposed to restart the timer", and the restart is not
# the missing part: `arm` resets the clock on every fresh cue, deliberately, including
# mid-rest. What goes missing is the cue. It rides back on the Done response and is swapped
# out of band, so a tap that never reaches the app produces no cue, and before this the clock
# stayed dead until a tap succeeded -- which in a basement gym is several minutes and several
# re-taps later.
#
# #516 shipped the other half of that: the banner and the row marks now say plainly that a tap
# was lost. What it does not do is start the rest, and a lifter who is told the tap failed is
# still standing in front of a bar with no clock on it -- which is the thing they were
# watching in the first place.
#
# **The fix is that the timer never needed the server.** The rest began when the lifter
# tapped, this browser was there, and the file's own rule is that it never asks the server
# what time it is -- so the failed path measures the rest with the identical clock the
# successful one uses.
#
# The signal is cut exactly as losing_signal_browser_spec cuts it, and that file records why:
# there is no Firefox equivalent of CDP's network emulation under Selenium, `.invalid` is
# reserved by RFC 6761 so no resolver may answer for it, and the rewrite has to go through
# innerHTML because htmx captures a verb and a path in a closure when it first processes a
# node. Rediscovering any of that here would be a second, worse copy of it.
module RestWithoutTheServer
  include LosingSignal
  include RestingBrowser

  # A session whose working sets carry the rest a block prescribed, so the reconciliation
  # specs have something for the late cue to bring that this browser could not know.
  def a_prescribed_session(seconds, sets: 1)
    workout_id = a_session_to_lift(sets:)
    DB[:sets].where(id: @set_ids).update(planned_rest_seconds: seconds)
    visit "/workouts/#{workout_id}/session"
    workout_id
  end

  def resting? = has_css?('#rest-timer', visible: true, wait: 5)
end

describe 'tapping Done when the tap does not arrive' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  before { a_tap_into_the_fog }

  # The whole of #513. The rest is happening whether or not the app heard about it.
  it 'starts the rest timer anyway' do
    assert resting?
    assert_operator seconds_in(clock_text), :<, 5
  end

  it "counts the rest from this browser's own clock" do
    assert resting?
    sleep 2.5

    assert_operator seconds_in(clock_text), :>, 0
  end

  # And it says so at the same time, because a clock running on a tap that failed would
  # otherwise be the app agreeing that the set was saved. The banner is what says otherwise,
  # and the two have to be on screen together -- since #542 in the words of a tap that is
  # being held rather than one that was lost, which is a better thing for a lifter watching
  # a rest count down to read.
  it 'is on screen beside the banner saying the tap has not gone yet' do
    assert resting?

    assert_text 'No connection. Your taps are being kept on this phone.'
    assert_selector '[data-set-row] p', text: 'Waiting to send.'
  end
end

# What a bar with no cue behind it may say, which is less than usual and is the interesting
# part of the answer. The clock is the browser's own, so it is as true as ever; everything
# else on this bar came off the cue, and the cue is exactly what did not arrive.
describe 'what the bar can claim with no cue behind it' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  before { a_tap_into_the_fog }

  # No movement name, no suggestion, no "prescribed". The prescription is looked up per
  # account and per movement on the server and rendered into the cue and nowhere else, so
  # there is no honest way to reach it from here -- and inventing one, or lifting the
  # movement's name out of the panel heading to make the bar look furnished, would be the app
  # claiming to know something it found out by guessing. This is the bar a movement with no
  # rest set has always shown.
  it 'offers the plain durations and claims nothing it was not told' do
    assert resting?

    assert has_css?('#rest-timer [data-rest-offer]', visible: true)
    refute has_css?('#rest-timer [data-rest-start="suggested"]', visible: true)
    refute has_css?('#rest-timer [data-rest-movement]', visible: true)
  end

  # Which is what makes the honest bar a usable one rather than an apology: a bell is one tap
  # away and it rings off the local clock like any other.
  it 'still rings if the lifter names a length' do
    assert resting?
    click_button '1:00'

    assert has_css?('#rest-timer [data-rest-steps]', visible: true)
    assert_equal 60, seconds_in(bell_text)
  end
end

describe 'tapping Done twice when neither tap arrives' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  # A lifter who taps and sees nothing taps again, harder -- the behaviour #516 opens with.
  # The second tap is not a second rest, and a clock that went back to 0:00 would tell them
  # their two-minute rest was four seconds old. The banner counts sets rather than taps for
  # the same reason.
  it 'keeps counting the one rest' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert resting?
    sleep 2.5
    standing = seconds_in(clock_text)
    tap_done

    assert_text '1 set waiting to send.'
    assert_operator seconds_in(clock_text), :>=, standing
  end
end

# The interesting half. A rest this browser started on its own has no stamp, because there was
# no response to carry one -- and when the lifter re-taps and it lands, a perfectly good cue
# arrives for the same set. Arming off it would reset the clock to 0:00 with the lifter minutes
# into their rest, which is a worse bug than the one #513 fixes: it is silent, and it looks
# exactly like the timer working.
describe 'the cue that turns up late' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  it 'does not restart a rest already running for that set' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert resting?
    sleep 3
    standing = seconds_in(clock_text)
    restore_the_signal
    tap_done
    assert_button 'Undo'

    assert_operator seconds_in(clock_text), :>=, standing,
                    'the real cue restarted a rest that was already running'
  end
end

# The local clock wins on *when* and the cue wins on *what*: the rest began at the first tap,
# and what the cue brings is the prescription this browser had no way to know.
describe 'the prescription a late cue brings with it' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  # The bell the cue would have armed is armed, measured from the original tap rather than
  # from the one that got through -- the network coming back is not part of anybody's rest.
  # Where the outage outlasted the prescription this lands on ringAt's "already past it"
  # case, which reports the overshoot rather than beeping at somebody mid-set.
  it 'arms the bell it would have armed, timed from the first tap' do
    a_prescribed_session(300)
    cut_the_signal
    tap_done
    assert resting?
    refute has_css?('#rest-timer [data-rest-steps]', visible: true)
    sleep 3
    standing = seconds_in(clock_text)
    restore_the_signal
    tap_done
    assert_button 'Undo'

    assert has_css?('#rest-timer [data-rest-steps]', visible: true, wait: 5)
    assert_equal 300, seconds_in(bell_text)
    assert_equal 'prescribed', find('[data-rest-source]').text
    assert_operator seconds_in(clock_text), :>=, standing
  end
end

# A different set finishing is a different rest, and it takes the bar over -- which is the
# rule that was already there for a cue landing mid-rest. The suppression above is keyed on
# the set, so this is what says it is keyed on the set and not on "any cue while something is
# running".
describe 'a cue for a set other than the one that was lost' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  it 'starts the rest over, because it is a different rest' do
    lose_one_and_save_the_next

    assert resting?
    assert_operator seconds_in(clock_text), :<, 5
  end
end

describe 'a late cue arriving on a bell the lifter already chose' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  # It does not overrule them. Somebody who got tired of waiting and tapped 1:00 has named a
  # length, and a prescription arriving afterwards is not a reason to move their bell -- nor
  # to call their number one the programme wrote.
  it 'leaves the bell exactly where they put it' do
    a_prescribed_session(300)
    cut_the_signal
    tap_done
    assert resting?
    click_button '1:00'
    restore_the_signal
    tap_done
    assert_button 'Undo'

    assert_equal 60, seconds_in(bell_text)
    refute has_css?('#rest-timer [data-rest-source]', visible: true)
  end
end

# The taps that do not finish a set must not start a rest when they fail, for the same reason
# the server does not cue one when they succeed. This is the rule rest_timer_spec pins on the
# cue, read back on the browser's side of the wire.
describe 'a lost tap that was never going to finish a set' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include RestWithoutTheServer

  # Tapping Done a second time takes a mis-tap back. It is not the end of a set, it must not
  # offer a rest -- and it must not throw away the rest you are in the middle of either, which
  # is what restarting the clock here would do.
  it 'leaves the running rest alone when the tap was an undo' do
    a_session_to_lift
    tap_done
    assert resting?
    sleep 2.5
    standing = seconds_in(clock_text)
    cut_the_signal
    find('button', text: 'Undo').click
    assert_text 'No connection. Your taps are being kept on this phone.'

    assert_operator seconds_in(clock_text), :>=, standing
  end

  # Fixing the weight two reps into a set is not doing the set (#215), so a correction that
  # fails leaves the bar exactly as shut as it was.
  it 'starts nothing when the tap was a correction' do
    a_session_to_lift
    cut_the_signal
    find('summary', text: 'Lifted something else').click
    fill_in "weight-#{@set_ids.first}", with: '145'
    click_button 'Save'
    assert_text 'No connection. Your taps are being kept on this phone.'

    refute has_css?('#rest-timer', visible: true)
  end
end

