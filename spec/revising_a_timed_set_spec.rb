# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # login; idempotent require

# Found reviewing the session screen at phone width. "Lifted something else" on a plank offered a
# Reps box, and typing how long it was held into it sent a rep count onto a set measured in
# seconds -- which sets_measures_one_way refuses, so the save was a 500 on the gym floor.
module RevisingATimedSet
  def revision_form(body) = body[%r{<form action="/workouts/\d+/sets/#{@set}/complete"[^>]*items-end.*?</form>}m]

  def save(field, value)
    post "/workouts/#{@workout}/sets/#{@set}/complete",
         { '_csrf' => @form[/name="_csrf" value="([^"]+)"/, 1], field => value }
  end
end

describe 'revising a set held for time' do
  include Rack::Test::Methods
  include RouteOwnership
  include RevisingATimedSet

  before do
    account_id = login
    @workout = DB[:workouts].insert(account_id:, date: Date.today)
    plank = DB[:exercises].insert(name: "Plank #{SecureRandom.hex(3)}", account_id:)
    @set = DB[:sets].insert(workout_id: @workout, exercise_id: plank, measure: 'time', duration_seconds: 45,
                            is_warmup: false)
    get "/workouts/#{@workout}/session"
    @form = revision_form(last_response.body)
  end

  it 'asks for seconds, not reps' do
    assert_includes @form, 'name="duration_seconds"'
    refute_includes @form, 'name="reps"'
  end

  it 'saves the seconds held' do
    save('duration_seconds', '60')

    assert_equal 60, DB[:sets].where(id: @set).get(:duration_seconds)
  end

  # A reps field sent anyway -- an old page, a hand-made post -- is ignored rather than refused.
  it 'ignores a rep count sent for it' do
    save('reps', '60')

    refute_equal 500, last_response.status
    assert_nil DB[:sets].where(id: @set).get(:reps)
  end
end

