# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its login, workout and token helpers; idempotent require

# #631. Logging a session by hand was one trip per set: a form with no heading, a movement box
# that started on Anderson Squat, and a save that ended on a read-only page with nowhere to go
# but back. The form now names the session, comes back to itself after a save, and starts on
# what was last logged.
module AddingSets
  def squat = Tectonic::Exercise.where(account_id: nil, name: 'Back Squat').get(:id)

  def form_for(workout_id)
    get "/workouts/#{workout_id}/sets/new"
    last_response.body
  end

  def save_set(workout_id, exercise_id, weight, reps)
    path = "/workouts/#{workout_id}/sets/new"
    post path, { exercise_id:, weight:, reps:, '_csrf' => token_for(path) }
  end

  def chosen(body) = body[/<option value="(\d*)" selected/, 1]
end

describe 'adding sets to a workout from its page' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingSets

  before do
    @account_id = login
    @workout = own_workout(@account_id)
  end

  it 'says which session the set is going into' do
    assert_match(/<h1[^>]*>\s*Add a set to/, form_for(@workout))
  end

  it 'comes back to the form after a save, saying what was saved' do
    save_set(@workout, squat, 135, 5)
    follow_redirect!

    assert_equal "/workouts/#{@workout}/sets/new", last_request.path
    assert_includes last_response.body, 'Saved Back Squat'
    assert_includes last_response.body, 'go back to the workout'
  end

  # The next set of a 3 x 5 is one Save: the same movement and numbers are already there.
  it 'starts the next set on the same movement and numbers' do
    save_set(@workout, squat, 135, 5)
    body = form_for(@workout)

    assert_equal squat.to_s, chosen(body)
    assert_match(/id="weight"[^>]*value="135"/m, body)
    assert_match(/id="reps"[^>]*value="5"/m, body)
  end
end

describe 'the movement a first set starts on' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingSets

  before { @account_id = login }

  # An account that has never logged a set starts on nothing rather than on whichever
  # movement sorts first, and saving without choosing one says so.
  it 'is nothing at all for an account that has never logged one' do
    body = form_for(own_workout(@account_id))

    assert_equal '', chosen(body)
    refute_match(/<option value="\d+" selected/, body)
  end

  it 'asks for a movement rather than dropping the set silently' do
    workout = own_workout(@account_id)
    save_set(workout, '', 135, 5)
    follow_redirect!

    assert_includes last_response.body, 'Choose a movement for the set'
  end
end

