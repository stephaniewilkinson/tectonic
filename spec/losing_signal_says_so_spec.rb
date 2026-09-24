# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The markup half of #516: what the session screen carries so that a failed tap can be
# reported at all, asserted without a browser because none of this is a clock or a network.
#
# The behaviour -- a Done tap that never reaches the server, and what a lifter sees when it
# does not -- is in losing_signal_browser_spec.rb, which drives a real Firefox at a host
# nothing can reach. What is here is the half that file could only assert expensively and
# indirectly: that the banner starts hidden rather than greeting every session with a
# warning, that nothing htmx swaps contains it, and that every set row carries both the
# handle the script finds it by and the line it fills in.
module LosingSignal
  def a_session(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, reps: 5, weight: 155, is_barbell: true, is_completed: false }
    @warmup_id = DB[:sets].insert(**common, is_warmup: true)
    @set_id = DB[:sets].insert(**common, is_warmup: false)
    workout_id
  end

  # What a Done tap sends back: the one lift panel, plus the progress header, the live
  # region, the two cues and the re-armed poller out of band beside it.
  def tap(workout_id, set_id)
    action = "/workouts/#{workout_id}/sets/#{set_id}/complete"
    token = token_for_form("/workouts/#{workout_id}/session", action)
    post action, { '_csrf' => token }, { 'HTTP_HX_REQUEST' => 'true' }
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # And what the poll sends back, which is every panel on the screen.
  def poll(workout_id, body)
    get "/workouts/#{workout_id}/session/changes", since: body[/[?&]since=([a-f0-9]+)/, 1]
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end
end

describe 'the session screen before anything has gone wrong' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # It greets nobody with a warning. The banner is on the page from the first paint because
  # a script that had to build one would have to build it at the moment the network is gone,
  # and a hidden element is the cheapest possible way to have it ready before then.
  it 'carries the offline banner, hidden' do
    assert_match(/<div id="offline-banner" hidden/, @body)
  end

  # Every line it can say starts hidden, and they are separate lines because they stop being
  # true at different moments: the connection comes back in an instant, the taps being held
  # go out over the following second, and a set the server refused stays refused until
  # somebody taps it again.
  it 'hides all of the things it can say until one of them is true' do
    assert_match(/<p data-offline-kept hidden/, @body)
    assert_match(/<p data-offline-unkept hidden/, @body)
    assert_match(/<p data-offline-held hidden/, @body)
    assert_match(/<p data-offline-sending hidden/, @body)
    assert_match(/<p data-offline-lost hidden/, @body)
  end

  # The region the script announces through is the one the server already announces every
  # tap into (#336), rather than a second one of the banner's own. A lifter who cannot see
  # the banner is told in the same place, and in the same voice, as "squat, set 3 of 5,
  # done" -- and two live regions on one screen is two things talking over each other.
  it 'announces through the live region the server already uses' do
    assert_includes @body, 'id="session-announcement"'
    assert_includes @body, "getElementById('session-announcement')"
  end
end

describe 'where the banner is not' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # The claim the placement actually rests on, and it is asserted against the responses
  # rather than against the nesting on the page, because "outside the region htmx replaces"
  # is a claim about what comes back from these two routes and nothing else. Inside that
  # region the banner would be replaced by every request that succeeded and left alone by
  # every request that failed -- the right answer for the wrong reason, and one that stops
  # being right the moment anything else on the screen swaps.
  it 'is in nothing a tap sends back' do
    refute_includes tap(@workout_id, @set_id), 'offline-banner'
  end

  it 'is in nothing the poll sends back' do
    refute_includes poll(@workout_id, @body), 'offline-banner'
  end
end

describe 'the two things the banner can say about a connection' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # They differ in what they promise, and which is true is decided by something the browser
  # only answers at load: whether there is a store to hold a tap in at all. A lifter in a
  # private window, or on a phone that refuses the database, must not be told their taps are
  # being kept -- that is the lie #516 exists to remove, wearing the opposite words. So both
  # are on the page and the script shows whichever it can stand behind. #542.
  it 'carries the promise it can keep and the one it cannot' do
    assert_includes @body, 'No connection. Your taps are being kept on this phone.'
    assert_includes @body, 'No connection. Nothing you tap is being saved.'
  end

  # And neither of them is in anything htmx swaps, like the rest of the banner: a sentence
  # about whether requests are arriving cannot live in the region those requests replace.
  it 'keeps them out of what a tap sends back' do
    refute_includes tap(@workout_id, @set_id), 'No connection.'
  end
end

describe 'every row of a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # Warmups as well as working sets. A ramp step is tapped off through the same route by the
  # same button, and a lifter who lost one has exactly the same problem.
  it 'carries the handle the banner marks it by' do
    rows = @body.scan(/data-set-row="(\d+)"/).flatten

    assert_equal [@warmup_id.to_s, @set_id.to_s].sort, rows.sort
  end

  it 'carries a hidden line saying the tap did not save' do
    assert_equal 2, @body.scan('<p data-unsaved hidden').length
  end

  # And the line it wears while the queue is holding it, which is the ordinary case since
  # #542 and a different claim: the tap is not in the database and it is not lost either.
  # Two elements rather than one with its words rewritten by the script, so that both
  # sentences are in the template where they can be read beside the rows they appear on.
  it 'carries a hidden line saying the tap is waiting to send' do
    assert_equal 2, @body.scan('<p data-waiting hidden').length
    assert_includes @body, 'Waiting to send.'
  end
end

describe 'what a row says about a tap and what it does not' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # Words rather than a colour, which is what #214 settled for this row: the tint has two
  # states, done and not, and a set the app failed to save is not a third state of the set.
  # The set is exactly as unfinished as the row already shows; what is new is a statement
  # about the tap.
  it 'says so in words rather than repainting the row' do
    assert_includes @body, 'Not saved.'
    refute_match(/<li data-set-row="\d+"[^>]*class="[^"]*amber/, @body)
  end

  # The reason the script has to remember which rows it marked rather than trusting the DOM
  # to keep them. A tap on one set re-renders its whole panel and the poll re-renders every
  # panel on the screen, and both send these rows back with both lines hidden -- correctly,
  # because as far as the database is concerned neither thing has happened to this set.
  it 'comes back from a tap with both lines hidden again' do
    assert_match(/<p data-unsaved hidden/, tap(@workout_id, @set_id))
    assert_match(/<p data-waiting hidden/, tap(@workout_id, @set_id))
  end
end

describe 'the poller on a screen with a queue behind it' do
  include Rack::Test::Methods
  include RouteOwnership
  include LosingSignal

  before do
    @workout_id = a_session(login)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # What a flush leaves behind is a screen that is out of date about itself: the sets went in
  # by fetch, so nothing swapped, and the rows still show Done on work the database now has.
  # The poll would find that within fifteen seconds on its own. Fifteen seconds is a long
  # time to stand there having watched the count go to zero, so the drain says so and the
  # poller listens -- one extra trigger on an element that already exists, rather than a
  # second request of the queue's own asking the same question. #542.
  it 'refreshes the panels when the queue has finished sending' do
    assert_match(/hx-trigger="every 15s, queue-drained from:body[^"]*"/, @body)
  end

  # And it comes back on every tap carrying the same trigger, because this element replaces
  # itself out of band and a poller that forgot how to listen would leave the screen stale
  # after the first flush of the session rather than after none of them.
  it 'keeps the trigger through the swap that replaces it' do
    assert_match(/hx-trigger="every 15s, queue-drained from:body[^"]*"/, tap(@workout_id, @set_id))
  end
end

