# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/measured'

# Editing a set through the form at /workouts/:id/sets/:set_id/edit.
#
# #213. A set counts in reps or in seconds and never in both, and the database says so
# outright -- sets_measures_one_way refuses a row with a rep count under measure 'time', or
# without one under measure 'reps'. The form posted reps whatever the set was measured in
# and the route wrote what it was handed, so both halves of that constraint were reachable
# from a page of ordinary inputs. Neither was handled: the violation came back as an
# unrescued Sequel exception, which reaches a person as a 500 and loses what they typed.
#
# The two ways in are a rep count cleared on a set that is measured in reps, and a rep count
# typed on one measured in seconds -- which the form used to offer no way to avoid, since
# Reps was the only quantity field it had.
module SetEditing
  def app
    Tectonic.app
  end

  def a_workout
    @account_id = login
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now)
  end

  # A movement of this account's own, so the edit is allowed and the library is untouched.
  def a_movement
    DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id: @account_id)
  end

  def repped_set(weight: 135, reps: 5)
    DB[:sets].insert(workout_id: @workout_id, exercise_id: a_movement, weight:, reps:,
                     is_warmup: false, is_completed: false, is_barbell: true)
  end

  # A plank, as ProgramGenerator writes one: a duration, no rep count, and the measure that
  # keeps the two straight.
  def timed_set(seconds: 60)
    DB[:sets].insert(workout_id: @workout_id, exercise_id: a_movement, weight: nil,
                     reps: nil, duration_seconds: seconds,
                     measure: Tectonic::Measured.stored(Tectonic::Measured::TIME),
                     is_warmup: false, is_completed: false, is_barbell: false)
  end

  def edit(set_id)
    get "/workouts/#{@workout_id}/sets/#{set_id}/edit"
    last_response.body
  end

  def save(set_id, params)
    path = "/workouts/#{@workout_id}/sets/#{set_id}"
    post path, params.merge('_csrf' => token_for("#{path}/edit"))
    last_response
  end

  def row(set_id)
    DB[:sets].where(id: set_id).first
  end
end

describe 'editing a set measured in reps' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetEditing

  before { a_workout }

  it 'saves the weight and the rep count' do
    id = repped_set

    assert_equal 302, save(id, { 'weight' => '145', 'reps' => '3' }).status
    assert_equal 3, row(id)[:reps]
    assert_in_delta 145, row(id)[:weight].to_f
  end

  # The crash. A cleared Reps box is one keystroke away on a form that does not mark the
  # field required when it is editing, and it took the whole save down with it.
  it 'refuses a cleared rep count rather than raising' do
    id = repped_set
    response = save(id, { 'weight' => '145', 'reps' => '' })

    assert_equal 302, response.status
    assert_match %r{/sets/#{id}/edit\z}, response.headers['location'],
                 'a refused edit should come back to the form, not to the record'
    assert_equal 5, row(id)[:reps], 'and should leave the set as it was'
    assert_in_delta 135, row(id)[:weight].to_f, 0.001, 'including the weight it did not save'
  end
end

describe 'editing a set measured in seconds' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetEditing

  before { a_workout }

  # The form had no field for the one number this set is made of, so the thing you opened
  # the page to change was the thing you could not reach.
  it 'is offered the duration rather than a rep count' do
    body = edit(timed_set(seconds: 45))

    assert_includes body, 'name="duration_seconds"'
    assert_includes body, 'value="45"'
    refute_includes body, 'name="reps"'
  end

  it 'saves a new duration' do
    id = timed_set(seconds: 45)

    assert_equal 302, save(id, { 'weight' => '', 'duration_seconds' => '90' }).status
    assert_equal 90, row(id)[:duration_seconds]
    assert_nil row(id)[:reps], 'a timed set holds no rep count'
  end

  it 'refuses a cleared duration rather than raising' do
    id = timed_set(seconds: 45)
    response = save(id, { 'weight' => '', 'duration_seconds' => '' })

    assert_equal 302, response.status
    assert_equal 45, row(id)[:duration_seconds], 'the set should be left as it was'
  end
end

# The measure is read off the row rather than off the post, so a field that arrives anyway
# -- from the old form, a stale tab, or by hand -- cannot push a set into a shape its
# movement disagrees with. This is the other half of the constraint, and the half a person
# could reach just by typing into the only quantity box the old form had.
describe 'the measure a set counts in' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetEditing

  before { a_workout }

  it 'is not changed by posting the other measure' do
    id = timed_set(seconds: 45)

    assert_equal 302, save(id, { 'weight' => '', 'reps' => '10', 'duration_seconds' => '45' }).status
    assert_nil row(id)[:reps]
    assert_equal 45, row(id)[:duration_seconds]
  end

  it 'keeps a repped set on reps when a duration is posted' do
    id = repped_set

    assert_equal 302, save(id, { 'weight' => '145', 'reps' => '3', 'duration_seconds' => '60' }).status
    assert_equal 3, row(id)[:reps]
    assert_nil row(id)[:duration_seconds]
  end
end

describe 'creating a set with no rep count' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetEditing

  before { a_workout }

  # required on the input is the browser's rule and stops at the browser.
  it 'is refused rather than raising' do
    path = "/workouts/#{@workout_id}/sets/new"
    before_count = DB[:sets].where(workout_id: @workout_id).count
    post path, { 'weight' => '135', 'reps' => '', 'exercise_id' => a_movement.to_s,
                 '_csrf' => token_for(path) }

    assert_equal 302, last_response.status
    assert_equal before_count, DB[:sets].where(workout_id: @workout_id).count
  end
end

