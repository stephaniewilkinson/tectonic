# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'
require 'date'

# One more set, from the screen you are holding. #496.
#
# The screenshot on that issue is the last lift of a session -- Dumbbell Skull Crusher, 7 of 7
# -- with both sets done and nowhere to put a third. "Add a set" has existed since the
# beginning on the workout record and the set list, and both are two pages away from the
# session. So deciding to do one more set meant leaving the session, adding it, and coming
# back.
#
# That is #365's friction in a different place, and worse here: the decision is made between
# two sets rather than before them.
module AddingASet
  def a_lift_of(account_id, sets: 2, completed: true)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    exercise = Tectonic::Exercise.create(account_id:, name: "Skull Crusher #{SecureRandom.hex(4)}",
                                         is_barbell: false)
    sets.times do |index|
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id,
                                  weight: 20 + (index * 10), reps: 10 + index, is_warmup: false,
                                  is_barbell: false, **Tectonic::WorkoutSet.completion(completed))
    end
    [workout, exercise]
  end

  def add(workout, exercise, headers = {})
    action = "/workouts/#{workout.id}/session/add"
    post action, { 'exercise_id' => exercise.id.to_s,
                   '_csrf' => token_for_form("/workouts/#{workout.id}/session", action) }, headers
  end

  def sets_of(workout, exercise)
    Tectonic::WorkoutSet.where(workout_id: workout.id, exercise_id: exercise.id).order(:id).all
  end
end

describe 'adding a set from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  before do
    @account_id = login
    @workout, @exercise = a_lift_of(@account_id)
  end

  it 'offers the control' do
    get "/workouts/#{@workout.id}/session"

    assert_includes last_response.body, "/workouts/#{@workout.id}/session/add"
    assert_includes last_response.body, 'Add a set'
  end

  it 'adds one' do
    add(@workout, @exercise)

    assert_equal 3, sets_of(@workout, @exercise).length
  end

  # A plan until somebody taps Done, which is what every other set on this screen means by
  # being there. A set arriving already ticked would make "11 of 16" a count of things nobody
  # did.
  it 'arrives as a set still to do, carrying the last one numbers' do
    add(@workout, @exercise)
    added = sets_of(@workout, @exercise).last

    refute added.is_completed
    assert_equal 30, Tectonic::Plates.numeric(added.weight)
    assert_equal 11, added.reps
  end
end

# Offered even when every set is lifted, which is the case in the report -- and is exactly
# when a lifter decides to do one more.
describe 'adding a set to a lift that is finished' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  it 'is still offered' do
    account_id = login
    workout, = a_lift_of(account_id, completed: true)

    get "/workouts/#{workout.id}/session"

    assert_includes last_response.body, 'Add a set'
  end

  # #364 says lifted sets record what happened and must not move, which is why the movement
  # swap hides here. It says nothing about adding a new set beside them.
  it 'leaves the sets already lifted alone' do
    account_id = login
    workout, exercise = a_lift_of(account_id, completed: true)
    before = sets_of(workout, exercise).map { |set| [set.id, set.is_completed] }

    add(workout, exercise)

    assert_equal(before, sets_of(workout, exercise).first(2).map { |set| [set.id, set.is_completed] })
  end
end

# The flags a set carries are facts about how the movement is done, so a copy has to bring
# them: a per-side set that came back bilateral would halve the volume it counts (#320).
describe 'what the copied set brings with it' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  it 'keeps the per-side and barbell answers' do
    account_id = login
    workout, exercise = a_lift_of(account_id)
    sets_of(workout, exercise).last.update(is_per_side: true, is_barbell: true)

    add(workout, exercise)
    added = sets_of(workout, exercise).last

    assert added.is_per_side
    assert added.is_barbell
  end
end

# The screen has to come back describing the session that now exists: the progress header
# counts every set, so adding one moves "11 of 16" and the estimate beside it.
describe 'what the screen sends back' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  before do
    @account_id = login
    @workout, @exercise = a_lift_of(@account_id)
    add(@workout, @exercise, { 'HTTP_HX_REQUEST' => 'true' })
  end

  it 'updates the progress header out of band' do
    assert_includes last_response.body, 'hx-swap-oob'
  end

  it 'counts the set that was just added' do
    assert_includes last_response.body.gsub(/\s+/, ' '), 'of 3 sets'
  end
end

# A movement not in this session is what the swap control and the record page are for, and an
# id that is not there is a stale panel or a hand-made request. Neither should produce a set.
describe 'adding a set of something not in the session' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  it 'writes nothing' do
    account_id = login
    workout, = a_lift_of(account_id)
    stranger = Tectonic::Exercise.create(account_id:, name: "Curl #{SecureRandom.hex(4)}")
    before = Tectonic::WorkoutSet.where(workout_id: workout.id).count

    add(workout, stranger)

    assert_equal before, Tectonic::WorkoutSet.where(workout_id: workout.id).count
  end
end

describe 'adding a set to another account session' do
  include Rack::Test::Methods
  include RouteOwnership
  include AddingASet

  it 'does not reach it' do
    login
    theirs, exercise = a_lift_of(DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com",
                                                      password_hash: 'x'))
    before = Tectonic::WorkoutSet.where(workout_id: theirs.id).count

    post "/workouts/#{theirs.id}/session/add", { 'exercise_id' => exercise.id.to_s }

    assert_equal before, Tectonic::WorkoutSet.where(workout_id: theirs.id).count
  end
end

