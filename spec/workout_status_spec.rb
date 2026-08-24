# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

# The smallest block that can stand behind a generated workout: what makes a session a
# plan is the program day it came from, so a status spec needs a real one.
def program_day_for(account_id)
  program = Tectonic::Program.create(account_id:, name: "S#{SecureRandom.hex(4)}", block: 0,
                                     start_date: Date.today)
  week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
  Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1, focus: 'Squat')
end

def workout_for(account_id, date:, program_day_id: nil)
  Tectonic::Workout.create(account_id:, date:, program_day_id:)
end

def log_one_set(workout, is_completed:)
  exercise_id = Tectonic::Exercise.insert(account_id: workout.account_id, name: "L#{SecureRandom.hex(4)}")
  Tectonic::Set.insert(workout_id: workout.id, exercise_id:, weight: 100, reps: 5,
                       is_warmup: false, is_completed:)
end

describe 'a generated session' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @day = program_day_for(@account_id)
  end

  it 'is planned while its date is still ahead' do
    assert_equal :planned, workout_for(@account_id, date: Date.today + 3, program_day_id: @day.id).status
  end

  it 'is skipped once its date has passed with nothing lifted' do
    assert_equal :skipped, workout_for(@account_id, date: Date.today - 1, program_day_id: @day.id).status
  end

  it 'is performed as soon as one of its sets is completed' do
    workout = workout_for(@account_id, date: Date.today - 1, program_day_id: @day.id)
    log_one_set(workout, is_completed: true)
    assert_equal :performed, workout.status
  end

  it 'stays planned while its sets are written but unlifted' do
    workout = workout_for(@account_id, date: Date.today + 1, program_day_id: @day.id)
    log_one_set(workout, is_completed: false)
    assert_equal :planned, workout.status
  end
end

describe 'a workout logged by hand' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  it 'is history rather than a skipped plan, however long ago it was' do
    assert_equal :performed, workout_for(@account_id, date: Date.today - 30).status
  end

  it 'is planned when it was deliberately dated ahead' do
    assert_equal :planned, workout_for(@account_id, date: Date.today + 5).status
  end
end

# Today is the boundary this whole distinction turns on, so it gets a block of its own:
# both kinds of session dated today, before anything has been lifted and after.
describe 'a session dated today' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  # The row from the issue. Nothing has been lifted in it and there is no program day to
  # mark it as written, so it used to fall past every clause and come out as history.
  it 'is a plan when it was logged by hand and nothing has been lifted' do
    assert_equal :planned, workout_for(@account_id, date: Date.today).status
  end

  # A generated session dated today already read as a plan, and through program_day_id
  # rather than through its date at all. Pinned so that what today's programmed session
  # rests on is visibly not the comparison this fix changed.
  it 'is a plan when it came from a program day' do
    day = program_day_for(@account_id)
    assert_equal :planned, workout_for(@account_id, date: Date.today, program_day_id: day.id).status
  end

  it 'turns into history as soon as one set in it is lifted' do
    workout = workout_for(@account_id, date: Date.today)
    log_one_set(workout, is_completed: true)
    assert_equal :performed, workout.status
  end

  # Both neighbours, so the boundary cannot quietly move by a day again: yesterday is
  # over, and an untouched session logged for it is a record of a day that has been and
  # gone, while tomorrow has not started.
  it 'sits between a yesterday that is history and a tomorrow that is a plan' do
    assert_equal :performed, workout_for(@account_id, date: Date.today - 1).status
    assert_equal :planned, workout_for(@account_id, date: Date.today + 1).status
  end
end

describe 'a list of workouts' do
  it 'carries whether each was lifted, so no row loads its sets to be classified' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    lifted = workout_for(account_id, date: Date.today - 2)
    log_one_set(lifted, is_completed: true)
    log_one_set(workout_for(account_id, date: Date.today - 1), is_completed: false)
    rows = Tectonic::Workout.where(account_id:).with_performance.order(:id).all
    assert(rows.all? { |workout| workout.values.key?(:is_performed) })
    assert_equal [true, false], rows.map(&:performed?)
  end
end

describe 'the workouts index' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'separates the sessions still to train from the training already done' do
    account_id = login
    workout_for(account_id, date: Date.today + 2, program_day_id: program_day_for(account_id).id)
    workout_for(account_id, date: Date.today - 2)
    get '/workouts'
    positions = ['Upcoming', (Date.today + 2).strftime('%b %d, %Y'), 'History',
                 (Date.today - 2).strftime('%b %d, %Y')].map { |text| last_response.body.index(text) }
    assert_equal positions.compact.sort, positions
  end

  # The issue as a lifter meets it. Opening the page mid-morning, before anything has
  # been lifted, the row wanted is the one for today, and it used to be filed under
  # History with the sessions that are over. Asserted through the rendered page rather
  # than against the status symbol, because the partition is what actually decides
  # which of the two tables a session is drawn into.
  it "puts today's untouched session under Upcoming and not under History" do
    account_id = login
    workout_for(account_id, date: Date.today)
    workout_for(account_id, date: Date.today - 2)
    get '/workouts'
    positions = ['Upcoming', Date.today.strftime('%b %d, %Y'), 'History',
                 (Date.today - 2).strftime('%b %d, %Y')].map { |text| last_response.body.index(text) }
    assert_equal positions.compact.sort, positions
  end
end

