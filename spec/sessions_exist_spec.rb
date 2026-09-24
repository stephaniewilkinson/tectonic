# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'query_count_spec' # its query tally; idempotent require
require_relative '../lib/tectonic/program_schedule'
require 'securerandom'

# Sessions exist without anybody asking for them. #411.
#
# A week of workouts only existed when somebody said "generate week 3", and an assistant only
# acts when it is messaged -- so the way you found out there was no session for today was by
# opening the app on Monday morning and finding nothing there.
#
# #411 argues for dropping the programme screens, and names this as the dependency that
# creates. It also says the app should do this **regardless of whether the rest is ever done**,
# which is why it landed on its own and first.
module SessionsExist
  # A block of `weeks` weeks, one training day a week, opening on `start_date`.
  def block(account_id, start_date:, weeks: 4)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    program = Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}",
                                       start_date:, is_ascending: true)
    (1..weeks).each { |number| training_week(program, exercise, number, start_date.wday) }
    program
  end

  def training_week(program, exercise, number, weekday)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number:)
    training_day(week, exercise.id, weekday)
  end

  def training_day(week, exercise_id, weekday)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday:)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 0,
                                 sets: 3, reps: 5, top_weight: 155, progression: 'linear',
                                 is_barbell: true, is_main: true)
  end

  # Every week of a block made `days` training days long rather than one.
  def widen(program, days)
    exercise_id = program.program_weeks.first.program_days.first.program_lifts.first.exercise_id
    program.program_weeks.each do |week|
      (1...days).each { |offset| training_day(week, exercise_id, (program.start_date.wday + offset) % 7) }
    end
  end

  def sessions(account_id) = Tectonic::Workout.where(account_id:).count

  def dates(account_id) = Tectonic::Workout.where(account_id:).select_map(:date).map(&:to_date).sort
end

describe 'arriving at an app whose block has never been generated' do
  include SessionsExist

  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @monday = Date.today - ((Date.today.wday - 1) % 7)
    @program = block(@account_id, start_date: @monday)
  end

  it 'writes the sessions rather than leaving the week empty' do
    assert_equal 0, sessions(@account_id)

    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)

    assert_operator sessions(@account_id), :>, 0
  end

  # Two weeks rather than one, which is the other half of what #411 asks for: next week's
  # sessions are already there to be looked at, edited, or moved.
  it 'writes next week too, not only this one' do
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)

    assert_equal [@monday, @monday + 7], dates(@account_id)
  end

  # The whole reason this can run on every page load. The generator is idempotent on
  # (account, program day), so a second visit finds everything already there.
  it 'writes nothing the second time' do
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)
    before = sessions(@account_id)
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)

    assert_equal before, sessions(@account_id)
  end
end

# The window is the current week and the next, so it advances a week at a time as the block
# runs rather than writing the whole thing up front -- later weeks get edited as data arrives,
# which is why this does not run to the end.
describe 'a block already under way' do
  include SessionsExist

  it 'moves the window on as the block progresses' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    monday = Date.today - ((Date.today.wday - 1) % 7)
    block(account_id, start_date: monday)
    Tectonic::ProgramSchedule.ensure_ahead(account_id, monday)
    Tectonic::ProgramSchedule.ensure_ahead(account_id, monday + 7)

    assert_equal [monday, monday + 7, monday + 14], dates(account_id)
  end
end

# A block outside its own dates is not something to write sessions for.
describe 'a block that is not running today' do
  include SessionsExist

  before { @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x') }

  it 'writes nothing before it starts' do
    monday = Date.today + 30
    block(@account_id, start_date: monday)
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, Date.today)

    assert_equal 0, sessions(@account_id)
  end

  # Writing past the end of a block would invent training nobody planned.
  it 'writes nothing once its last week is behind us' do
    started = Date.today - 70
    block(@account_id, start_date: started, weeks: 2)
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, Date.today)

    assert_equal 0, sessions(@account_id)
  end

  # The window runs off the end rather than past it: on the last week there is no next one to
  # write, and asking for it must not raise.
  it 'writes only what exists on the final week' do
    started = Date.today - 7
    block(@account_id, start_date: started, weeks: 2)
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, Date.today)

    assert_equal 1, sessions(@account_id)
  end
end

# Somebody arriving has come to look at their training. A block the generator refuses must not
# turn the page they landed on into a 500 on the way past.
describe 'a block the generator cannot write' do
  include SessionsExist

  it 'does not raise into the request' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    program = block(account_id, start_date: Date.today)
    # A percentage with no max to resolve against, and no weight either: the shape the
    # generator refuses.
    Tectonic::ProgramLift.where(program_day_id: program.week(1).program_days.map(&:id))
                         .update(top_weight: nil, percent_of_max: 80)

    Tectonic::ProgramSchedule.ensure_ahead(account_id, Date.today)
  end
end

describe 'the pages that keep sessions written' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionsExist

  # The calendar, because it is where somebody lands to ask what they are doing this week --
  # and because a session signed in once and left open for a fortnight never passes the
  # sign-in hook again.
  it 'writes them when the calendar is opened' do
    account_id = login
    block(account_id, start_date: Date.today)

    assert_equal 0, sessions(account_id)

    get '/'

    assert_operator sessions(account_id), :>, 0
  end

  # And on the way in, so "there is no session for today" is found out never rather than on a
  # Monday morning.
  it 'writes them on the way in from a sign-in' do
    account_id = login
    block(account_id, start_date: Date.today)
    Tectonic.new({}).login_destination(account_id)

    assert_operator sessions(account_id), :>, 0
  end
end

# #595. "A handful of indexed lookups" was the claim, and a visit that wrote nothing was
# measured at 25 queries -- on the front page and on every login. It grew with the days in
# the running block, since each day asked separately whether it had a session, and with every
# block the account had ever run, since each finished one was still read to be told it had
# finished. A lifter a few years in pays for all of that on every visit.
#
# So a steady-state visit costs the same whatever the running block's week looks like and
# however many blocks are behind it, and it is a handful.
describe 'a visit when every session is already written' do
  include SessionsExist
  include QueryCount

  def account_with(days:, finished:)
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    finished.times { |ago| block(account_id, start_date: @monday - (7 * 4 * (ago + 1)) - 7) }
    widen(block(account_id, start_date: @monday), days)
    Tectonic::ProgramSchedule.ensure_ahead(account_id, @monday)
    account_id
  end

  def visit_cost(account_id)
    queries_while { Tectonic::ProgramSchedule.ensure_ahead(account_id, @monday) }
  end

  before { @monday = Date.today - ((Date.today.wday - 1) % 7) }

  it 'does not grow with the days in a week or the blocks behind it' do
    small = visit_cost(account_with(days: 1, finished: 0))
    large = visit_cost(account_with(days: 5, finished: 4))

    assert_equal small, large
    assert_operator large, :<=, 6
  end
end

# #584. A program day with nothing written on it got an empty session every week, and the
# calendar drew each one as missed once its day had passed -- a session nobody could have done,
# counted against the lifter. An empty day is a rest day now.
describe 'a program day with no lifts on it' do
  include SessionsExist

  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @monday = Date.today - ((Date.today.wday - 1) % 7)
    @program = block(@account_id, start_date: @monday)
    @program.program_weeks.each { |week| Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 3) }
  end

  it 'gets no session' do
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)

    assert_equal [@monday, @monday + 7], dates(@account_id)
  end

  # A session somebody already has for such a day is theirs, and may have lifts added by hand.
  it 'leaves a session that already exists for it alone' do
    empty_day = Tectonic::ProgramDay.first(weekday: 3, program_week_id: @program.program_weeks.first.id)
    Tectonic::Workout.create(account_id: @account_id, date: @monday + 2, program_day_id: empty_day.id)
    Tectonic::ProgramSchedule.ensure_ahead(@account_id, @monday)

    assert_equal 1, Tectonic::Workout.where(program_day_id: empty_day.id).count
  end
end

