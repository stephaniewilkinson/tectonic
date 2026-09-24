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
  # the next set is tapped off, which re-renders the lost set's row from a server that has
  # never heard of it.
  def lose_one_and_save_the_next
    a_session_to_lift(sets: 2)
    cut_the_signal
    tap_done(0)
    assert_text 'No connection. Nothing you tap is being saved.'
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
  it 'says there is no connection' do
    assert_text 'No connection. Nothing you tap is being saved.'
  end

  # And says how much was lost, which is the number that tells a lifter whether to worry.
  it 'counts what did not save' do
    assert_text '1 set did not save.'
  end

  # Named on the row as well as counted in the banner, because "one set did not save" across
  # a twelve-set session is not an answer to "which one".
  it 'marks the row the tap was on' do
    assert_selector '[data-set-row] p', text: 'Not saved.'
  end

  # It does not fake the save. #516 is explicit: don't tint the row green, because a count of
  # sets that did not land is honest and more useful than a screen that agrees with you.
  it 'leaves the set exactly as unfinished as it is' do
    assert_button 'Done'
    refute_button 'Undo'
    refute completed?, 'the tap never reached the server, so nothing should have been written'
  end

  # Through the region the server already announces every tap into (#336), so a lifter who
  # cannot see the banner is told in the same place as "squat, set 3 of 5, done".
  it 'reads the same news out to a screen reader' do
    assert_selector '#session-announcement', visible: :all, text: 'Offline. 1 set did not save.'
  end
end

describe 'tapping Done twice with no signal' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  # A lifter who taps and sees nothing taps again, harder. That is the behaviour the issue
  # opens with, and it must not read as two sets lost -- the count is of sets, not of taps.
  it 'still counts one set' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert_text '1 set did not save.'
    tap_done

    assert_text '1 set did not save.'
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
  it 'takes the banner down and saves the set that was lost' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert_text 'No connection. Nothing you tap is being saved.'

    restore_the_signal
    tap_done

    assert_button 'Undo'
    refute_text 'No connection'
    refute_text 'Not saved.'
    assert completed?, 'the second tap reached the server, so the set is done'
  end
end

describe 'a set lost while the next one goes through' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal

  before { lose_one_and_save_the_next }

  # The subtle half, and the one that would rot silently. A mark is not a thing the markup
  # can keep: the row it is in is re-rendered by a tap on any other set of the same lift and
  # by every poll that finds anything changed, and it comes back from the server hidden --
  # correctly, because as far as the database is concerned the tap it is about never
  # happened. So the script remembers which sets it marked and puts them back after every
  # swap, and this is the difference between that and a lifter watching the only evidence of
  # a lost set disappear the moment the signal returns.
  it 'still says the first one did not save' do
    assert_text '1 set did not save.'
    assert_selector '[data-set-row] p', text: 'Not saved.', count: 1
  end

  it 'has written the second set and not the first' do
    refute completed?(0), 'the first set is still the one nothing was ever written about'
    assert completed?(1), 'and the second went through'
  end

  # The connection is back, so the banner stops claiming otherwise -- while the line about
  # what was lost stays up, because that is still true and is the only thing telling a
  # lifter there is a set here to go back for.
  it 'stops saying there is no connection' do
    refute_text 'No connection'
  end
end

