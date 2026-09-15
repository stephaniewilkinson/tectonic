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

