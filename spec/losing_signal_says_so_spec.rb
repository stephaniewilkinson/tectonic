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

  # Both of its lines start hidden, and separately, because they stop being true at
  # different moments: the connection comes back in an instant and the sets it lost stay
  # lost until somebody taps them again.
  it 'hides both of the things it can say until one of them is true' do
    assert_match(/<p data-offline-state hidden/, @body)
    assert_match(/<p data-offline-lost hidden/, @body)
  end

  # The one the placement actually rests on, and it is asserted against the responses rather
  # than against the nesting on the page, because "outside the region htmx replaces" is a
  # claim about what comes back from these two routes and nothing else. Inside that region
  # the banner would be replaced by every request that succeeded and left alone by every
  # request that failed -- the right answer for the wrong reason, and one that stops being
  # right the moment anything else on the screen swaps.
  it 'is in nothing a tap sends back' do
    refute_includes tap(@workout_id, @set_id), 'offline-banner'
  end

  it 'is in nothing the poll sends back' do
    refute_includes poll(@workout_id, @body), 'offline-banner'
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
  # panel on the screen, and both send these rows back hidden -- correctly, because as far
  # as the database is concerned the lost tap never happened.
  it 'comes back from a tap with the line hidden again' do
    assert_match(/<p data-unsaved hidden/, tap(@workout_id, @set_id))
  end
end

