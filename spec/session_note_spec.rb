# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'
require 'date'

# How the session went, written where it happened. #452.
#
# `workouts.note` has existed since #310, and the only way to write one was the workout edit
# form -- a different page, reached by leaving the session. So the note this column exists
# for, "bar felt slow today, slept badly", had to survive the walk to another screen and a
# lifter remembering to take it.
#
# It is the context that explains an RPE three weeks later, and it is worth nothing if it is
# not written within about a minute of the set that prompted it.
module SessionNote
  def a_session(account_id)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout.id, exercise_id:, weight: 155, reps: 5,
                     is_warmup: false, is_completed: false, is_barbell: true)
    workout
  end

  def session_page(workout)
    get "/workouts/#{workout.id}/session"
    last_response.body
  end

  def write(workout, note, headers = {})
    action = "/workouts/#{workout.id}/session/note"
    post action, { 'note' => note, '_csrf' => token_for_form("/workouts/#{workout.id}/session", action) },
         headers
  end
end

describe 'writing a note from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before do
    @account_id = login
    @workout = a_session(@account_id)
  end

  it 'offers somewhere to write one' do
    assert_includes session_page(@workout), 'name="note"'
  end

  it 'saves it' do
    write(@workout, 'Bar felt slow today, slept badly.')

    assert_equal 'Bar felt slow today, slept badly.', @workout.refresh.note
  end

  # Blank clears, on the same terms as every other note in this app (#310): a note written
  # after a bad day can be taken back off without leaving an empty paragraph behind.
  it 'clears it when the box is emptied' do
    write(@workout, 'Slept badly.')
    write(@workout, '   ')

    assert_nil @workout.refresh.note
  end

  it 'reads back what was written' do
    write(@workout, 'Left knee grumbling.')

    assert_includes session_page(@workout), 'Left knee grumbling.'
  end
end

# The screen is read at arm's length between sets, so a textarea cannot sit open above the
# lift panels. Open only when there is something to see.
describe 'how much room the note takes' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before do
    @account_id = login
    @workout = a_session(@account_id)
  end

  it 'is collapsed while there is no note' do
    refute_match(/<details[^>]*\sopen/, session_page(@workout))
  end

  # A note you cannot see is a note you write twice, and the second visit is usually to add
  # to it rather than to start one.
  it 'is open once there is' do
    write(@workout, 'Slept badly.')

    assert_match(/<details[^>]*\sopen/, session_page(@workout))
  end

  it 'says which job it is doing' do
    assert_includes session_page(@workout), 'Add a note'
    write(@workout, 'Slept badly.')

    assert_includes session_page(@workout), 'Session note'
  end
end

# The htmx answer is the note block alone. Sending back the session body would re-render every
# lift panel, closing any disclosure the lifter had open and scrolling the horizontal lift
# strip back to the start -- while they stand in front of a loaded bar.
describe 'what saving a note sends back' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before do
    @account_id = login
    @workout = a_session(@account_id)
    write(@workout, 'Slept badly.', { 'HTTP_HX_REQUEST' => 'true' })
    @body = last_response.body
  end

  it 'is the note block and not the whole session' do
    assert_includes @body, 'id="session-note"'
    refute_includes @body, 'id="lift-panels"'
  end

  it 'says it saved' do
    assert_includes @body, 'Saved.'
  end

  # "Saved" under an empty box would be reporting on a note that was just cleared, which is
  # true and reads as a failure.
  it 'does not say so when the note was cleared' do
    write(@workout, '', { 'HTTP_HX_REQUEST' => 'true' })

    refute_includes last_response.body, 'Saved.'
  end
end

# The route sits inside the nested workout gate, which resolves `@workout` scoped to the
# account and redirects before any of the session routes run.
#
# Tested through the gate rather than by posting with a borrowed token: Roda binds a CSRF
# token to the path it was issued for, so a token from my own session would be refused for
# being the wrong token and the assertion would pass without the ownership check ever running.
# A test that passes for the wrong reason is worse here than no test.
describe 'another account session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before do
    login
    @theirs = a_session(DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x'))
  end

  it 'does not open, so its note form is unreachable' do
    get "/workouts/#{@theirs.id}/session"

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], '/workouts'
  end

  it 'is not writable through the note route either' do
    post "/workouts/#{@theirs.id}/session/note", { 'note' => 'nope' }

    assert_nil @theirs.refresh.note
  end
end

