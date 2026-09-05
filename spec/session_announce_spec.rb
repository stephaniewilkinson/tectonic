# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What the session screen tells a reader who cannot see it. #336 and #338, from the #328
# audit, together because both are about the same screen saying nothing useful out loud and
# the second makes the first worse: adding a live region while the ticking clock is still
# exposed would read the elapsed time aloud every second.
module Announce
  def session_with(completed: false)
    account_id = login
    workout_id = own_workout(account_id)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    set_id = DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5, is_barbell: true,
                              is_warmup: false, **Tectonic::WorkoutSet.completion(completed))
    [workout_id, set_id]
  end

  def screen(workout_id)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  def tap(workout_id, set_id)
    action = "/workouts/#{workout_id}/sets/#{set_id}/complete"
    # The htmx header, or the route redirects instead of returning the partials -- and the
    # live region rides back on the partials.
    post action, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", action) },
         { 'HTTP_HX_REQUEST' => 'true' }
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end
end

describe 'the live region on the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include Announce

  # It has to be in the document before anything happens: a live region announces changes
  # to itself, so one that arrives already carrying its sentence says nothing at all.
  it 'is on the page from the first render, and empty' do
    workout_id, = session_with
    body = screen(workout_id)

    assert_match(/<div id="session-announcement"[^>]*aria-live="polite"/, body)
    assert_match(%r{<div id="session-announcement"[^>]*></div>}, body)
  end

  it 'is announced politely rather than assertively' do
    workout_id, = session_with
    body = screen(workout_id)

    assert_includes body, 'role="status"'
    refute_includes body, 'aria-live="assertive"'
  end
end

describe 'what a tap announces' do
  include Rack::Test::Methods
  include RouteOwnership
  include Announce

  # Which movement, what was on the bar, what it now is, and where that leaves the session --
  # the same four things the screen says visually when the row turns green.
  it 'names the set, its state and the count' do
    workout_id, set_id = session_with
    body = tap(workout_id, set_id)
    said = body[%r{<div id="session-announcement"[^>]*>([^<]*)</div>}, 1]

    assert_includes said, 'Back Squat'
    assert_includes said, '225 lb'
    assert_includes said, 'Done'
    assert_includes said, '1 of 1 sets'
  end

  # Read back off the row after the write rather than from what was posted, so an undo says
  # so instead of repeating the word on the button that was tapped.
  it 'says not done when a tap takes a set back' do
    workout_id, set_id = session_with(completed: true)
    said = tap(workout_id, set_id)[%r{<div id="session-announcement"[^>]*>([^<]*)</div>}, 1]

    assert_includes said, 'Not done'
    assert_includes said, '0 of 1 sets'
  end

  # Out of band, or it would land wherever the response was aimed -- which is the lift panel,
  # inside the element the poll replaces.
  it 'comes back out of band' do
    workout_id, set_id = session_with

    assert_match(/<div id="session-announcement" hx-swap-oob="true"/, tap(workout_id, set_id))
  end
end

# #336's caveat, and the reason it had to be fixed in the same change: the comment in
# _progress.erb said the ticking clock was aria-hidden and the attribute was on the middot
# beside it. Harmless while nothing announced anything; unusable the moment something does.
describe 'the ticking session clock' do
  include Rack::Test::Methods
  include RouteOwnership
  include Announce

  # Two sets completed a while apart, because a session only has an elapsed time once there
  # is a span between a first and a last -- one set is an instant, not a duration.
  it 'is hidden from a screen reader, since it changes every second' do
    workout_id, set_id = session_with(completed: true)
    exercise_id = DB[:sets].where(id: set_id).get(:exercise_id)
    DB[:sets].where(id: set_id).update(completed_at: Time.now - 3600)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5, is_barbell: true,
                     is_warmup: false, is_completed: true, completed_at: Time.now)
    body = screen(workout_id)
    clock = body[/<span id="session-clock"[^>]*>/]

    refute_nil clock, 'the clock should be on the screen once a set is done'
    assert_includes clock, 'aria-hidden="true"'
  end

  # The count beside it is the part a lifter wants read back, and it does not tick.
  it 'leaves the set count announced' do
    workout_id, = session_with

    assert_match(/<p class="mt-1[^"]*">\s*0 of 1 sets/, screen(workout_id))
  end
end

# #338: twelve buttons called "Done" and up to sixty called a single digit, with nothing in
# any of their names saying which set they belong to.
describe 'the accessible names of the session buttons' do
  include Rack::Test::Methods
  include RouteOwnership
  include Announce

  it 'says what the Done button acts on' do
    workout_id, = session_with

    assert_includes screen(workout_id), 'aria-label="Done: Back Squat'
  end

  it 'says Undo on a set already lifted' do
    workout_id, = session_with(completed: true)

    assert_includes screen(workout_id), 'aria-label="Undo: Back Squat'
  end
end

describe 'the accessible names of the rating buttons' do
  include Rack::Test::Methods
  include RouteOwnership
  include Announce

  # A screen reader's list of controls is where the group label is lost, and a list is the
  # complaint: five digits per set, sixty on a session, all reading "7, button".
  it 'names every rating button with the set it rates' do
    workout_id, = session_with
    body = screen(workout_id)

    (6..10).each do |rating|
      assert_includes body, %(aria-label="RPE #{rating} for Back Squat)
    end
  end

  # The RPE caption was a bare span attached to nothing, so even the scale went unannounced.
  it 'attaches the RPE caption to the buttons it captions' do
    workout_id, set_id = session_with
    body = screen(workout_id)

    assert_includes body, %(role="group" aria-labelledby="rpe-label-#{set_id}")
    assert_includes body, %(id="rpe-label-#{set_id}")
  end

  # The visible text stays one word and one digit. That is what makes the screen readable at
  # arm's length with chalk on, and the whole reason the name is carried in an attribute.
  it 'leaves the visible labels alone' do
    workout_id, = session_with
    body = screen(workout_id)

    assert_match(%r{>\s*Done\s*</button>}, body)
    assert_match(%r{>\s*7\s*</button>}, body)
  end
end

