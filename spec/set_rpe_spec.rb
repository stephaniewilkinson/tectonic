# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

def own_lift(account_id, name = 'Back Squat')
  Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}")
end

# A set of `exercise`, lifted unless the caller says otherwise, since what a max is read
# from is completed work.
def log_lifted_set(workout_id, exercise, attributes)
  written = { reps: 5, rpe: nil, is_completed: true, is_warmup: false }.merge(attributes)
  Tectonic::WorkoutSet.insert(workout_id:, exercise_id: exercise.id, **written)
end

describe 'rating a set in the session view' do
  include Rack::Test::Methods
  include RouteOwnership

  # The session page renders one form per set, each carrying a token for its own path,
  # and this workout holds exactly one set -- so the page's first token is that set's.
  it 'records the rating on the set and counts as having lifted it' do
    account_id = login
    workout_id = own_workout(account_id)
    set_id = log_lifted_set(workout_id, own_lift(account_id), weight: 155, reps: 5, is_completed: false)
    get "/workouts/#{workout_id}/session"

    post "/workouts/#{workout_id}/sets/#{set_id}/complete",
         { 'rpe' => '9', '_csrf' => token_from(last_response.body) }

    assert_equal [9, true], Tectonic::WorkoutSet[set_id].values.values_at(:rpe, :is_completed)
  end
end

describe 'an estimated max' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = own_lift(@account_id)
  end

  it 'comes from the account\'s own completed sets and rises with the best of them' do
    workout_id = Tectonic::Workout.insert(account_id: @account_id, date: Date.today)
    log_lifted_set(workout_id, @exercise, weight: 155, reps: 5, rpe: 8)
    assert_equal 191, @exercise.estimated_max(account_id: @account_id)
    log_lifted_set(workout_id, @exercise, weight: 185, reps: 3, rpe: 8)
    assert_equal 214, @exercise.estimated_max(account_id: @account_id)
  end

  it 'ignores a set that was only written and never lifted' do
    workout_id = Tectonic::Workout.insert(account_id: @account_id, date: Date.today)
    log_lifted_set(workout_id, @exercise, weight: 225, reps: 3, rpe: 8, is_completed: false)
    assert_nil @exercise.estimated_max(account_id: @account_id)
  end
end

describe 'an estimated max over time' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = own_lift(@account_id)
  end

  it 'answers as of a date, so a block\'s progress can be read week by week' do
    old = Tectonic::Workout.insert(account_id: @account_id, date: Date.today - 14)
    recent = Tectonic::Workout.insert(account_id: @account_id, date: Date.today - 1)
    log_lifted_set(old, @exercise, weight: 155, reps: 5, rpe: 8)
    log_lifted_set(recent, @exercise, weight: 185, reps: 5, rpe: 8)
    assert_equal 191, @exercise.estimated_max(account_id: @account_id, on: Date.today - 7)
    assert_equal 228, @exercise.estimated_max(account_id: @account_id)
  end

  it "never reaches another account's lifting of a shared movement" do
    stranger = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    workout_id = Tectonic::Workout.insert(account_id: stranger, date: Date.today)
    log_lifted_set(workout_id, @exercise, weight: 405, reps: 1, rpe: 10)
    assert_nil @exercise.estimated_max(account_id: @account_id)
  end
end

describe 'a lift written as a percentage' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = own_lift(@account_id)
    @program = Tectonic::Program.create(account_id: @account_id, name: "P#{SecureRandom.hex(4)}",
                                        block: 0, start_date: Date.new(2026, 8, 17))
    week = Tectonic::ProgramWeek.create(program_id: @program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1, focus: 'Squat')
    @lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: @exercise.id, position: 0,
                                         sets: 3, reps: 5, top_weight: nil, percent_of_max: 80,
                                         progression: 'percent')
  end

  it 'takes its load from the estimated max at generation time' do
    workout_id = Tectonic::Workout.insert(account_id: @account_id, date: Date.today)
    log_lifted_set(workout_id, @exercise, weight: 155, reps: 5, rpe: 8) # a max of 191
    generated = Tectonic::ProgramGenerator.new(@program).generate(1).first
    top = Tectonic::WorkoutSet.where(workout_id: generated.id).max(:weight)
    assert_equal 155, top # 80% of 191, rounded to what a bar can hold
  end

  it 'refuses to invent a max when nothing has been lifted yet' do
    error = assert_raises(ArgumentError) { Tectonic::ProgramGenerator.new(@program).generate(1) }
    assert_includes error.message, 'No estimated max'
  end
end

