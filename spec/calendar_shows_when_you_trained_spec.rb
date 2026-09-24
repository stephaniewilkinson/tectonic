# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/calendar'
require_relative '../lib/tectonic/workouts'
require 'securerandom'
require 'date'

# The calendar draws a session on the day it was trained. #479.
#
# `workouts.date` is when a session was *written for*. For a generated block that is a plan
# made weeks ahead, and training does not keep to it. On the reporting account five sessions
# were trained up to three days from the date they carry -- one written for 2026-09-17 was
# lifted on the 14th -- and the calendar drew every one of them on the planned day.
#
# So the grid answered "what was I going to do" while looking exactly like an answer to "when
# did I train", which is the only question a diary is for. A session lifted on Monday appeared
# on Thursday, and Monday looked like a rest day.
module CalendarTruth
  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')

  # A session written for one day and trained on another, which is the reported shape.
  def a_session(account_id, written_for:, trained_on: nil, sets: 2)
    workout = Tectonic::Workout.create(account_id:, date: written_for)
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    sets.times do
      DB[:sets].insert(workout_id: workout.id, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: !trained_on.nil?,
                       completed_at: trained_on && Time.new(trained_on.year, trained_on.month,
                                                            trained_on.day, 18, 0, 0))
    end
    workout
  end

  # `month` is the first of the month as a Date, which is what the route passes.
  def days(account_id, month, today)
    Tectonic::Calendar.weeks(account_id, month, today)
                      .flatten.to_h { |cell| [cell[:date], cell[:workouts]] }
  end
end

describe 'a session trained before the day it was written for' do
  include CalendarTruth

  before do
    @account_id = an_account
    @written_for = Date.new(2026, 9, 17)
    @trained_on = Date.new(2026, 9, 14)
    @workout = a_session(@account_id, written_for: @written_for, trained_on: @trained_on)
    @days = days(@account_id, Date.new(2026, 9, 1), Date.new(2026, 9, 15))
  end

  # The complaint, exactly: it showed when they were planned, not when they were done.
  it 'is drawn on the day it was trained' do
    assert_equal [@workout.id], @days[@trained_on].map(&:id)
  end

  it 'is not drawn on the day it was written for' do
    assert_empty @days[@written_for]
  end

  # And it still reads as training rather than as a plan, which it already did -- the word was
  # right and the cell was wrong.
  it 'still reads as trained' do
    assert_equal :performed, @days[@trained_on].first.status(Date.new(2026, 9, 15))
  end
end

# The other direction, which is the same bug and the one that makes a calendar lie about a
# rest day: a session written for Monday and actually done on Wednesday.
describe 'a session trained after the day it was written for' do
  include CalendarTruth

  it 'moves forward to the day it happened' do
    account_id = an_account
    workout = a_session(account_id, written_for: Date.new(2026, 9, 7), trained_on: Date.new(2026, 9, 9))

    grid = days(account_id, Date.new(2026, 9, 1), Date.new(2026, 9, 30))

    assert_equal [workout.id], grid[Date.new(2026, 9, 9)].map(&:id)
    assert_empty grid[Date.new(2026, 9, 7)]
  end
end

# A plan is still a plan. Nothing about this moves a session that has not been trained.
describe 'a session nobody has trained yet' do
  include CalendarTruth

  it 'stays on the day it is written for' do
    account_id = an_account
    workout = a_session(account_id, written_for: Date.new(2026, 9, 24))

    grid = days(account_id, Date.new(2026, 9, 1), Date.new(2026, 9, 15))

    assert_equal [workout.id], grid[Date.new(2026, 9, 24)].map(&:id)
    assert_equal :planned, grid[Date.new(2026, 9, 24)].first.status(Date.new(2026, 9, 15))
  end
end

# Sessions whose sets were completed before #281 gave them a stamp cannot say when they
# happened. The planned date is the best available answer rather than a guess.
describe 'a session completed with no stamp to read' do
  include CalendarTruth

  it 'stays where it was stored' do
    account_id = an_account
    workout = a_session(account_id, written_for: Date.new(2026, 9, 10))
    workout.sets_dataset.update(is_completed: true, completed_at: nil)

    grid = days(account_id, Date.new(2026, 9, 1), Date.new(2026, 9, 30))

    assert_equal [workout.id], grid[Date.new(2026, 9, 10)].map(&:id)
  end
end

# The fetch window has to follow the same rule, or a session simply vanishes: written for the
# 1st of next month and trained on the 30th of this one, it would be drawn on neither page.
describe 'a session that crosses a month boundary' do
  include CalendarTruth

  it 'appears in the month it was trained in, not the month it was written for' do
    account_id = an_account
    workout = a_session(account_id, written_for: Date.new(2026, 10, 1), trained_on: Date.new(2026, 9, 30))

    september = days(account_id, Date.new(2026, 9, 1), Date.new(2026, 10, 15))

    assert_equal [workout.id], september[Date.new(2026, 9, 30)].map(&:id)
  end

  it 'is gone from the month it was written for' do
    account_id = an_account
    a_session(account_id, written_for: Date.new(2026, 10, 1), trained_on: Date.new(2026, 9, 30))

    october = days(account_id, Date.new(2026, 10, 1), Date.new(2026, 10, 15))

    assert_empty october[Date.new(2026, 10, 1)]
  end
end

# A session spanning midnight belongs to the day it started, which is the one reading a stored
# date can never give and `completed_at` can.
describe 'a session that ran past midnight' do
  include CalendarTruth

  it 'belongs to the day it started' do
    account_id = an_account
    workout = Tectonic::Workout.create(account_id:, date: Date.new(2026, 9, 20))
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout.id, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                     is_completed: true, completed_at: Time.new(2026, 9, 20, 23, 40, 0))
    DB[:sets].insert(workout_id: workout.id, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                     is_completed: true, completed_at: Time.new(2026, 9, 21, 0, 30, 0))

    grid = days(account_id, Date.new(2026, 9, 1), Date.new(2026, 9, 30))

    assert_equal [workout.id], grid[Date.new(2026, 9, 20)].map(&:id)
    assert_empty grid[Date.new(2026, 9, 21)]
  end
end

# The same session across a month rather than a day, which #599 had to get right. The grid now
# fetches any session with a set completed inside it, which is looser than the first completion
# and draws on the first completion still -- so a session begun on the 31st and finished on the
# 1st is fetched into both months and must be drawn in one. November 2026 begins on a Sunday,
# so its grid does not reach back to the 31st, and the only day it could wrongly land on is
# the 1st.
describe 'a session that ran past midnight at the end of a month' do
  include CalendarTruth

  before do
    @account_id = an_account
    @workout = Tectonic::Workout.create(account_id: @account_id, date: Date.new(2026, 10, 31))
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id: @account_id)
    [Time.new(2026, 10, 31, 23, 40, 0), Time.new(2026, 11, 1, 0, 30, 0)].each do |completed_at|
      DB[:sets].insert(workout_id: @workout.id, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: true, completed_at:)
    end
  end

  it 'is drawn in the month it started' do
    october = days(@account_id, Date.new(2026, 10, 1), Date.new(2026, 11, 15))

    assert_equal [@workout.id], october[Date.new(2026, 10, 31)].map(&:id)
  end

  it 'is not drawn in the month it finished' do
    november = days(@account_id, Date.new(2026, 11, 1), Date.new(2026, 11, 15))

    assert(november.values.all?(&:empty?), 'the session was drawn in November as well')
  end
end

# 054's index is only used while its predicate covers what `Workout.completed_between` asks,
# and nothing else fails if the two drift apart -- the calendar reads the same rows either way,
# just by reading all of them. Read out of the catalogue for the same reason
# finding_the_questions_waiting_spec reads 044's: a planner on a fixture this size scans
# whatever indexes exist, so a plan would assert the size of the fixture.
describe 'the index a month of the calendar is found through' do
  it 'holds completed sets by their day' do
    definition = DB[:pg_indexes].where(indexname: 'sets_completed_on').get(:indexdef).to_s

    assert_includes definition, '((completed_at)::date), workout_id'
    assert_includes definition, 'WHERE (completed_at IS NOT NULL)'
  end

  it 'is what the lookup asks for' do
    sql = Tectonic::Workout.completed_between(Date.new(2026, 9, 1), Date.new(2026, 9, 30)).sql

    assert_includes sql, '"completed_at" IS NOT NULL'
    assert_includes sql, 'CAST("completed_at" AS date)'
  end
end

