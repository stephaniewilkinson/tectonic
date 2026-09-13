# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The calendar is a real table now. #339, from the #328 audit.
#
# It was two separate CSS grids -- one of seven day names, one of thirty-odd cells -- with
# nothing connecting a cell to the column above it. A screen reader read "Mon Tue Wed Thu Fri
# Sat Sun" and then a flat run of dates.
#
# The issue is careful that no information was lost, and it is right: each cell carries its own
# date, and the entries inside already carry sr-only text. What was missing was navigation.
# Answering "what am I doing on Thursday" meant listening to the whole month and counting,
# where a sighted reader glances at a column.
module CalendarNavigation
  def trained_today(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}")
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5, is_warmup: false,
                     is_completed: true, is_barbell: true, completed_at: Time.now)
    workout_id
  end

  def calendar = last_response.body[%r{<table.*?</table>}m].to_s
end

describe 'the calendar grid' do
  include Rack::Test::Methods
  include RouteOwnership
  include CalendarNavigation

  before do
    @account_id = login
    trained_today(@account_id)
    get '/'
  end

  it 'is a table rather than two runs of divs' do
    assert_includes calendar, '<table'
  end

  # The whole fix. Without it a reader has the cells and no way to tell which column any of
  # them is in.
  it 'heads every column with the day it is' do
    assert_equal 7, calendar.scan('scope="col"').length
  end

  # Spelled out for a reader and abbreviated on screen, because a seventh of a phone is not
  # wide enough for "Wednesday" and "Thu" announced alone is a step short of the answer.
  it 'announces the day in full while drawing the short form' do
    assert_includes calendar, '>Thursday</span>'
    assert_includes calendar, '>Thu</span>'
  end

  it 'says what the table is, for a reader who lands on it' do
    assert_match(/<caption[^>]*>\s*Training calendar for \w+ \d{4}/, calendar)
  end

  # A row per week, so moving down a column moves a week at a time.
  it 'puts each week in its own row' do
    assert_operator calendar.scan('<tr').length, :>=, 5
  end
end

# The short and full names are rotated together. Two lists rotated apart is the one way this
# goes wrong, and a header reading "Thu" while announcing "Friday" is worse than one that only
# ever says "Thu".
describe 'the column headings for an account that starts its week on Monday' do
  include Rack::Test::Methods
  include RouteOwnership
  include CalendarNavigation

  it 'begins on Monday in both the drawn and the announced name' do
    short, full = Tectonic::Calendar.day_columns(1).first

    assert_equal 'Mon', short
    assert_equal 'Monday', full
  end

  it 'begins on Sunday by default, which is where it always began' do
    assert_equal %w[Sun Sunday], Tectonic::Calendar.day_columns.first.to_a
  end

  # Seven columns, whichever day they start on, and each abbreviation against its own word.
  it 'keeps every pair in step however it is rotated' do
    Tectonic::Calendar::WEEK_STARTS.each do |starts_on|
      columns = Tectonic::Calendar.day_columns(starts_on)

      assert_equal 7, columns.length
      columns.each { |short, full| assert full.start_with?(short), "#{full} is not #{short}" }
    end
  end
end

# What the issue says was already working, and has to still be working: no information was
# lost before, so none may be lost by the markup changing underneath it.
describe 'what a reader could already get from a cell' do
  include Rack::Test::Methods
  include RouteOwnership
  include CalendarNavigation

  before do
    @account_id = login
    trained_today(@account_id)
    get '/'
  end

  it 'still carries the date number in every cell' do
    assert_match(/>\s*#{Date.today.day}\s*</, calendar)
  end

  it 'still says what happened on a day it was trained' do
    assert_includes calendar, 'trained'
  end

  it 'still links the session from its cell' do
    assert_match(%r{<a href="/workouts/\d+"}, calendar)
  end
end

