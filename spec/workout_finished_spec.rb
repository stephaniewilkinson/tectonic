# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require

# Saying a session is over. #218.
#
# The complaint was not about this app's screens: an assistant reading a training history
# treated a finished day as one still under way. It had no way not to. `status` is derived
# and `performed?` is *any one set completed*, so a session with three of ten done reported
# `performed` and nothing else -- and "I stopped early" and "I am between sets" are the same
# rows. No derivation separates them, which is why this is a thing the lifter says rather
# than a thing the app works out.
module FinishingASession
  def app
    Tectonic.app
  end

  # Ten sets, three of them ticked: the shape the complaint was about, where the count
  # alone cannot say whether the day is over.
  def part_done_session(done: 3, of: 10)
    account_id = login
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    of.times do |n|
      DB[:sets].insert(workout_id:, exercise_id:, weight: 100, reps: 5,
                       is_warmup: false, is_completed: n < done, is_barbell: true)
    end
    [account_id, workout_id]
  end

  # Found by the form's action rather than by taking the first token on the page: the
  # session screen carries a token per set as well, and "the first one" is a property of
  # where the finish button happens to sit rather than of what is being posted.
  def finish(workout_id)
    action = "/workouts/#{workout_id}/session/finish"
    post action, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", action) }
    last_response
  end
end

describe 'finishing a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include FinishingASession

  before { @account_id, @workout_id = part_done_session }

  it 'is not claimed of a session nobody has finished' do
    refute Tectonic::Workout[@workout_id].finished?
  end

  it 'is recorded, and lands on the record where the link used to go' do
    response = finish(@workout_id)

    assert_equal 302, response.status
    assert_equal "/workouts/#{@workout_id}", URI(response.headers['location']).path
    assert Tectonic::Workout[@workout_id].finished?
  end

  # The point of finishing at all: it says the day is over without pretending the sets
  # left undone were done. Those two facts are why one field could not carry both.
  it 'leaves the sets that were not done alone' do
    finish(@workout_id)

    assert_equal 3, DB[:sets].where(workout_id: @workout_id, is_completed: true).count
    assert_equal 10, DB[:sets].where(workout_id: @workout_id).count
  end
end

# What finishing deliberately does not do. Both of these are the reason it is its own
# field rather than a fourth value of `status` or a sweep that ticks the remaining sets.
describe 'what finishing a session leaves alone' do
  include Rack::Test::Methods
  include RouteOwnership
  include FinishingASession

  before { @account_id, @workout_id = part_done_session }

  # Finishing is a statement, not a gate. A set corrected afterwards is a correction to a
  # finished session, which is an ordinary thing to want.
  it 'does not lock the session against further edits' do
    finish(@workout_id)
    set_id = DB[:sets].where(workout_id: @workout_id, is_completed: false).order(:id).get(:id)
    action = "/workouts/#{@workout_id}/sets/#{set_id}/complete"
    post action, { '_csrf' => token_for_form("/workouts/#{@workout_id}/session", action) }

    assert_equal 302, last_response.status, 'the post should be accepted, not refused'
    assert DB[:sets].where(id: set_id).get(:is_completed), 'a finished session is still editable'
  end

  # status answers where a session stands in the plan -- written, missed, trained -- and
  # the calendar colours a cell by it. A finished session and one still under way are both
  # trained, so this deliberately does not become a fourth value there.
  it 'does not disturb the status a session already had' do
    finish(@workout_id)

    assert_equal :performed, Tectonic::Workout[@workout_id].status
  end
end

describe 'finishing a session that is not yours' do
  include Rack::Test::Methods
  include RouteOwnership
  include FinishingASession

  # The finish route sits inside the workout gate -- `r.redirect '/workouts' unless @workout
  # && @workout.account_id == @account_id` -- so a workout id belonging to somebody else
  # never resolves and none of show, edit, sets, session or this can be reached with one.
  #
  # Asserted as an outcome rather than as a status code, and deliberately: a token cannot
  # be obtained for a page this account may not load, so the post is refused before the
  # gate is even consulted. What matters is that the stranger's row is untouched by either
  # refusal, and that the page it would have come from is closed too.
  it "refuses another account's session" do
    _mine, mine = part_done_session
    stranger_workout, = strangers_workout

    get "/workouts/#{stranger_workout}/session"

    assert_equal 302, last_response.status
    assert_equal '/workouts', URI(last_response.headers['location']).path

    action = "/workouts/#{stranger_workout}/session/finish"
    post action, { '_csrf' => token_for_form("/workouts/#{mine}/session", "/workouts/#{mine}/session/finish") }

    assert_nil DB[:workouts].where(id: stranger_workout).get(:finished_at)
  end
end

# The surface the complaint actually came through.
describe 'what the session screen offers' do
  include Rack::Test::Methods
  include RouteOwnership
  include FinishingASession

  before { @account_id, @workout_id = part_done_session }

  it 'posts rather than only navigating, which is what the words promised' do
    get "/workouts/#{@workout_id}/session"

    assert_includes last_response.body, "/workouts/#{@workout_id}/session/finish"
    assert_includes last_response.body, 'finish workout'
  end

  it 'says so once the session has been finished' do
    finish(@workout_id)
    get "/workouts/#{@workout_id}/session"

    assert_match(%r{<button[^>]*>\s*finished\s*</button>}, last_response.body)
    refute_includes last_response.body, 'finish workout'
  end
end

describe 'the workouts list' do
  include Rack::Test::Methods
  include RouteOwnership
  include FinishingASession

  before { @account_id, @workout_id = part_done_session }

  # Quiet when nothing was said: an absent badge means "not said", not "abandoned".
  it 'stays quiet about a session nobody finished' do
    get '/workouts'

    refute_includes last_response.body, '>finished<'
  end

  it 'marks one that was finished' do
    finish(@workout_id)
    get '/workouts'

    assert_includes last_response.body, '>finished<'
  end
end

