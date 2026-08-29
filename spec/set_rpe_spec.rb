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

  # The session page renders one form per set, each carrying a token for its own path.
  # This used to take the page's first token, on the reasoning that a workout of one set
  # has only one form -- which stopped being true when #218 put the finish button above
  # the panels, and the first token became that button's. The post was then refused 403
  # and the set went unrated, which is a failure this spec would have reported as "the
  # rating was not recorded" without a hint as to why.
  #
  # token_for_form asks for the token of the form that posts where this is posting, which
  # is true however the page is later rearranged.
  it 'records the rating on the set and counts as having lifted it' do
    account_id = login
    workout_id = own_workout(account_id)
    set_id = log_lifted_set(workout_id, own_lift(account_id), weight: 155, reps: 5, is_completed: false)
    action = "/workouts/#{workout_id}/sets/#{set_id}/complete"

    post action, { 'rpe' => '9', '_csrf' => token_for_form("/workouts/#{workout_id}/session", action) }

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

  # "at generation time" until #291, which is the rule this now states the other way: the
  # max is read as of the block's start date, so every week of a wave is a percentage of
  # one number. The set therefore has to be dated on or before the day the block opened --
  # lifting done *after* it opened belongs to the block that comes next.
  it 'takes its load from the max as of the day the block opened' do
    workout_id = Tectonic::Workout.insert(account_id: @account_id, date: @program.start_date)
    log_lifted_set(workout_id, @exercise, weight: 155, reps: 5, rpe: 8) # a max of 191
    generated = Tectonic::ProgramGenerator.new(@program).generate(1).first
    top = Tectonic::WorkoutSet.where(workout_id: generated.id).max(:weight)
    assert_equal 155, top # 80% of 191, rounded to what a bar can hold
  end

  # Still a refusal after #264, and still for the same reason: with neither a stated max nor
  # lifting to derive one from there is nothing to take a percentage of, and a guess would
  # be a whole week of loads nobody chose. The message changed because the way out did --
  # stating a max is now a second remedy beside logging a set.
  # The other way out of this refusal -- stating a max, so a movement with nothing logged
  # can still be generated against -- is #264's own, and is tested in training_max_spec.rb
  # beside the rest of that rule rather than repeated here.
  it 'refuses to invent a max when nothing has been lifted yet' do
    error = assert_raises(ArgumentError) { Tectonic::ProgramGenerator.new(@program).generate(1) }
    assert_includes error.message, 'No training max'
  end
end

