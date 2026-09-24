# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'losing_signal_browser_spec' # reuses its fog, its sign-up and its taps

# #542, in the browser, which is the only place a queue exists at all.
#
# There is no Ruby in this half either -- stage zero changed the route so that a completion
# can arrive twice, and that is specced without a browser in a_tap_that_can_arrive_twice_spec
# -- so what is under test here is a store, a flush and five sentences. A lifter taps Done in
# a basement, the request never leaves the phone, and the tap is written to IndexedDB with
# the moment it was made on it. When anything reaches the server again the taps go out in the
# order they were made, and the screen stops talking about them.
#
# **The fog is #516's and is reused rather than rediscovered**: the page is pointed at a host
# under `.invalid`, which RFC 6761 reserves and no resolver may answer for, so the XHR fails
# and htmx fires a real htmx:sendError. Its two traps still apply -- an hx-post changed by
# setAttribute is an hx-post nothing reads, and the poller has to go into the same fog as the
# taps or the page can read while it cannot write.
#
# **A third trap belongs to this file, and it is the one that decides a design.** The fog is a
# *host*, so a queue that stored the URL a request was made to would store an unreachable one
# and could never replay it -- not here, and not in a gym, where the analogous thing is a
# captive portal rewriting a request that the browser will happily make again once it is past
# the portal. The queue stores the path. That is also the honest thing for it to hold: every
# request this page makes is same-origin, so the origin carries no information, and pinning a
# held tap to the host the page happened to be served from is how a queue survives a domain
# change by replaying to the old one.
#
# Background Sync is not involved and could not have been. Safari has never supported it on
# any platform, every browser on iOS is WebKit underneath, and the Firefox these specs drive
# does not support it either. Every flush below is driven by the page being open: a request
# that came back, a poll, or a page load.
module WaitingTaps
  # The one thing a spec cannot ask Capybara to wait for, because it is not on the screen.
  # Used only after an assertion about the screen has already waited for the same event.
  def completed_count = DB[:sets].where(id: @set_ids, is_completed: true).count

  # A fresh load of the same session, which is what a lifter does when they surface: the tab
  # was closed, or the phone locked and the page was thrown out of memory. Nothing of the
  # previous page survives it except the queue, which is the whole point.
  def open_the_session_again(workout_id) = visit("/workouts/#{workout_id}/session")
end

describe 'the signal coming back while the session is open' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal
  include WaitingTaps

  # The ordinary recovery: a set is lost to the fog, the bars come back, and the next set is
  # tapped off. #516 ended here with the first set still lost and a banner saying so -- which
  # was honest and is now unnecessary, because the tap that comes back is what tells the
  # queue there is a way out. Both sets are in the database and the lifter did nothing.
  it 'sends what it was holding when the next tap goes through' do
    a_session_to_lift(sets: 2)
    cut_the_signal
    tap_done(0)
    assert_text '1 set waiting to send.'
    restore_the_signal
    tap_done(1)

    refute_text 'waiting to send'
    refute_text 'No connection'
    assert_equal 2, completed_count
  end

  # And the recovery nobody taps for, which is the one a basement gym actually produces: the
  # lifter is sitting on a bench resting and the signal comes back on its own. The
  # fifteen-second poll is the only request this screen makes that nobody asked for, and
  # #516's banner already leans on it to notice an outage -- this is the same heartbeat
  # finding the way back. Nothing else on the page could: with every tap failing there is no
  # other request left to succeed.
  #
  # The wait is long because the poll is fifteen seconds and the drain and the re-render come
  # after it. It is the one spec here that pays for a real clock, and it is worth it: without
  # it the queue would only ever flush on something the lifter did, which is the design this
  # issue rules out in its first paragraph.
  it 'sends what it was holding when the poll finds the way back' do
    a_session_to_lift
    cut_the_signal
    tap_done
    assert_text '1 set waiting to send.'
    restore_the_signal

    using_wait_time(30) { assert_button 'Undo' }
    assert_equal 1, completed_count
  end
end

describe 'a queue outliving the page that made it' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal
  include WaitingTaps

  # Why this is IndexedDB and not a variable in a closure. A phone locks, a tab is discarded
  # to free memory, a lifter switches to the timer app and back: nothing of the page survives
  # any of those, and a queue that lived in the page would take the session with it. The
  # store is what the tap is written to, and the next load of this screen is what finds it.
  #
  # It is also the flush that needs no event at all. The page in front of the lifter was
  # fetched from the server, so there is a connection by construction, and the first thing
  # the queue does after opening is empty itself.
  before do
    @workout_id = a_session_to_lift
    cut_the_signal
    tap_done
    assert_text '1 set waiting to send.'
    open_the_session_again(@workout_id)
  end

  it 'sends the tap that was made before the page went away' do
    assert_button 'Undo'
    assert_equal 1, completed_count
  end

  it 'says nothing about a queue once it is empty' do
    assert_button 'Undo'

    refute_text 'waiting to send'
    refute_text 'No connection'
  end
end

describe 'a held tap the server will not take' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include LosingSignal
  include WaitingTaps

  # The case the queue must not loop on. A held tap can arrive at a server that refuses it --
  # the set was deleted from another device or by an assistant over MCP, the account was
  # signed out, the workout is gone -- and a refusal is not a network failure: it is the
  # server having had its say, which is the same distinction #516 draws between
  # htmx:sendError and htmx:responseError. So the tap comes off the queue rather than being
  # sent forever, and the lifter gets #516's sentence back, because for this set it is true
  # again: nothing saved it and nothing is going to.
  before do
    @workout_id = a_session_to_lift
    cut_the_signal
    tap_done
    assert_text '1 set waiting to send.'
    DB[:sets].where(id: @set_ids).delete
    open_the_session_again(@workout_id)
  end

  it 'says the set did not save' do
    assert_text '1 set did not save.'
  end

  it 'gives up rather than sending it forever' do
    assert_text '1 set did not save.'
    open_the_session_again(@workout_id)

    refute_text 'did not save'
    refute_text 'waiting to send'
  end
end

