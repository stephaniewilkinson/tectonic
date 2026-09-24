# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# #516, in a real browser, which is the only place this bug exists.
#
# Everything about it is a request that does not arrive. There is no Ruby in the feature at
# all -- no route changed, no column, no response -- so a Rack::Test spec can assert what
# the page carries and nothing about what it does, which is why this file is worth the cost
# of a Firefox. What is under test is htmx's swap rule: a failed request swaps nothing, so
# before this a tap that never reached the server and a tap that never happened produced
# byte-identical screens.
#
# **How the signal is cut.** #516 flagged this as the unspiked part and guessed right:
# there is no CDP equivalent of Network.emulateNetworkConditions for Firefox under
# Selenium, so the network cannot be turned off from the harness. What can be done is to
# point the page at somewhere no network can reach. `.invalid` is reserved by RFC 6761 and
# no resolver may answer for it, so the lookup fails, the XHR errors, and htmx fires the
# genuine htmx:sendError this feature is built on -- rather than a synthetic event
# dispatched by the spec, which would test that the handler is bound and nothing else.
#
# **What this file no longer claims.** #542 gave the screen a queue, so a tap that fails is
# held and sent again rather than merely reported, and two of the things asserted here became
# false: that a lost set stays lost until somebody taps it again, and the banner sentence
# that said nothing you tap is being saved. The describe about a mark surviving a swap went
# with them -- the mark it pinned is now removed by the flush that a successful tap triggers,
# so the property it was protecting is no longer observable from the outside. What is left
# here is the honest signal itself: that a failure to send is noticed, counted, named on the
# row and announced, and that a refusal from a reachable server is none of those things.
# a_tap_that_waits_for_signal_browser_spec.rb is where the holding and the sending are.
#
# The paths are rewritten through innerHTML and re-processed rather than by setting the
# attribute, which does not work: htmx captures the verb and the path in a closure when it
# first processes a node, so an hx-post changed afterwards is an hx-post nothing reads.
# Replacing the markup gives htmx.process fresh nodes to bind, and drops the old ones --
# including the poller, whose fifteen-second GET has to go through the same fog as the taps
# or the test would be a phone that cannot write but can somehow read.
module LosingSignal
  UNREACHABLE = 'http://offline.invalid/'

  # A copy of the sign-up walk until #575 put a confirmation email in the middle of one. The
  # shared helper in spec_helper writes the account and drives only the sign-in, and the note
  # there says why: nothing in this file is about how an account comes to exist.
  def a_lifter = sign_in_as_somebody_new

  # One lift, so that however many sets are asked for they share a panel -- which is what
  # makes a tap on the second of them re-render the first, and is the whole of the last
  # describe in this file.
  def a_session_to_lift(sets: 1)
    account_id = a_lifter
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    @set_ids = Array.new(sets) do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: false, is_barbell: true)
    end
    visit "/workouts/#{workout_id}/session"
    workout_id
  end

  # By position, because a session of one lift draws a Done on every row and click_button
  # would refuse an ambiguous match.
  def tap_done(position = 0) = all(:button, 'Done')[position].click

  # htmx refuses a cross-origin request outright unless told otherwise, and would fire
  # htmx:invalidPath instead of making one -- which is a different failure with a different
  # meaning, and not the one a basement gym produces.
  def rewrite_requests(from, to)
    page.execute_script(<<~JS)
      htmx.config.selfRequestsOnly = false;
      var body = document.getElementById('session-body');
      body.innerHTML = body.innerHTML.split('#{from}').join('#{to}');
      htmx.process(body);
    JS
  end

  def cut_the_signal = rewrite_requests('="/workouts/', "=\"#{UNREACHABLE}workouts/")
  def restore_the_signal = rewrite_requests("=\"#{UNREACHABLE}workouts/", '="/workouts/')

  def completed?(position = 0) = DB[:sets].where(id: @set_ids[position]).get(:is_completed)

  # The basement gym, in three lines.
  def a_tap_into_the_fog
    a_session_to_lift
    cut_the_signal
    tap_done
  end

  # And the sequence after it that a lifter actually goes through: the signal comes back and
  # the next set is tapped off. Until #542 that re-rendered the lost set's row from a server
  # that had never heard of it; now the tap coming back is also what tells the queue there is
  # a way out, so the held set goes with it.
  def lose_one_and_save_the_next
    a_session_to_lift(sets: 2)
    cut_the_signal
    tap_done(0)
    assert_text '1 set waiting to send.'
    restore_the_signal
    tap_done(1)
    assert_button 'Undo'
  end
end

describe 'tapping Done with no signal' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  before { a_tap_into_the_fog }

  # The whole of the bug, and the whole of the fix. Before this the screen said nothing at
  # all: the row did not tint, the count stayed where it was, and the rest timer -- which is
  # armed by an element the server sends back *with* the response -- never started. A lifter
  # three sets into squats had no way to tell a tap that failed from a tap they imagined.
  #
  # The second half of the sentence has changed since #542, and had to. It read "Nothing you
  # tap is being saved", which was true of this app until the queue existed and is the thing
  # that issue was opened to stop being true. It is still one sentence and it still says the
  # two things a lifter needs at arm's length -- there is no signal, and here is what is
  # happening to your taps -- but the second is now good news.
  it 'says there is no connection' do
    assert_text 'No connection. Your taps are being kept on this phone.'
  end

  # And says how much is being held, which is the number that tells a lifter whether to
  # worry. A count of sets, not of taps, and the same count #516 drew of what was lost.
  it 'counts what is waiting to send' do
    assert_text '1 set waiting to send.'
  end

  # Named on the row as well as counted in the banner, because "one set" across a twelve-set
  # session is not an answer to "which one".
  it 'marks the row the tap was on' do
    assert_selector '[data-set-row] p', text: 'Waiting to send.'
  end

  # It does not fake the save. #516 is explicit: don't tint the row green, because a count of
  # sets that did not land is honest and more useful than a screen that agrees with you. That
  # survives the queue intact and matters more with one -- a held tap is not a saved tap, and
  # the difference is a set the database has never heard of.
  it 'leaves the set exactly as unfinished as it is' do
    assert_button 'Done'
    refute_button 'Undo'
    refute completed?, 'the tap never reached the server, so nothing should have been written'
  end

  # Through the region the server already announces every tap into (#336), so a lifter who
  # cannot see the banner is told in the same place as "squat, set 3 of 5, done".
  it 'reads the same news out to a screen reader' do
    assert_selector '#session-announcement', visible: :all, text: 'Offline. 1 set waiting to send.'
  end
end

describe 'tapping Done twice with no signal' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  # A lifter who taps and sees nothing taps again, harder. That is the behaviour the issue
  # opens with, and it must not read as two sets lost -- the count is of sets, not of taps.
  # Both taps are held since #542, because they are both true statements about the same set
  # and sending the same statement twice costs nothing; the number a lifter reads is still
  # how much of the session is not in yet.
  it 'still counts one set' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert_text '1 set waiting to send.'
    tap_done

    assert_text '1 set waiting to send.'
  end
end

describe 'a tap the server refuses' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  # htmx:responseError is deliberately bound to nothing. A 404 or a 500 is the server
  # disagreeing with the request, and disagreeing is something only a reachable server can
  # do -- so telling the lifter they are offline would be a second lie replacing the first.
  #
  # The title is how the assertion waits for the refusal to have happened. Absence is the
  # claim being made, and an assertion about absence passes instantly whether the request
  # has finished or not, so there has to be something to wait for that says it has.
  it 'says nothing about the connection' do
    a_session_to_lift
    page.execute_script(<<~JS)
      document.body.addEventListener('htmx:responseError', function () { document.title = 'refused'; });
      var form = document.querySelector('form[hx-post*="/complete"]');
      form.outerHTML = form.outerHTML.replace(/hx-post="[^"]*"/, 'hx-post="/no-such-route"');
      htmx.process(document.getElementById('session-body'));
    JS
    tap_done

    assert_title 'refused'
    refute_text 'No connection'
    refute_text 'Not saved.'
    refute_text 'Waiting to send.'
  end
end

describe 'the signal coming back' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  # What clears the banner is a request that came back, never navigator.onLine saying so.
  # That property reports whether there is a link rather than whether anything is at the
  # other end of it -- gym wifi behind a captive portal reads as online all day -- and the
  # asymmetry is the usable part: false is trustworthy, true is a guess.
  #
  # The set is saved twice over here, which is the point of stage zero: the second tap
  # reaches the server, and the first -- held since the fog -- is flushed by that tap coming
  # back. Both say the set is done, and a completion that says what it wants rather than
  # asking for a flip can be said as often as it likes. Before #542 the second of them would
  # have un-done the first, which is the failure the whole issue is arranged around.
  it 'takes the banner down and saves the set that was lost' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert_text 'No connection. Your taps are being kept on this phone.'

    restore_the_signal
    tap_done

    assert_button 'Undo'
    refute_text 'No connection'
    refute_text 'waiting to send'
    assert completed?, 'the tap reached the server, so the set is done -- and stayed done'
  end
end

