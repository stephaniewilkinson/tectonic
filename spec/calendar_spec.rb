# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'
require 'date'

# The grid is a module so the month arithmetic can be asserted without a browser: whole
# weeks, Monday first, and the neighbouring days drawn but marked as outside the month.
# The status a cell carries is the one a workout already answers with, so what matters
# here is that the calendar reads it rather than inventing a second set of rules.
module CalendarData
  def app
    Tectonic.app
  end

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    @account_id = DB[:accounts].where(email:).get(:id)
  end

  def a_lift
    DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id: @account_id)
  end

  # A session on a day. `program_day_id` is what separates a written plan from a logged
  # session, and a completed set is what makes either one performed.
  def a_workout(on:, lifted: false, planned: false, account_id: @account_id)
    day = planned ? a_program_day : nil
    at = Time.new(on.year, on.month, on.day, 18, 0)
    id = DB[:workouts].insert(account_id:, date: at, program_day_id: day)
    DB[:sets].insert(workout_id: id, exercise_id: a_lift, weight: 100, reps: 5,
                     is_warmup: false, is_completed: lifted)
    id
  end

  # The cheapest real program day: the status only asks whether one exists.
  def a_program_day
    program = DB[:programs].insert(account_id: @account_id, name: 'Block', start_date: Date.today,
                                   is_ascending: true)
    week = DB[:program_weeks].insert(program_id: program, number: 1)
    DB[:program_days].insert(program_week_id: week, weekday: 0)
  end

  def cells(weeks)
    weeks.flatten
  end

  def cell_on(weeks, date)
    cells(weeks).find { |cell| cell[:date] == date }
  end
end

describe 'the calendar grid' do
  include Rack::Test::Methods
  include CalendarData

  # Whole weeks, so every row has seven days and the grid is rectangular.
  it 'covers the month in whole weeks beginning on Monday' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 2, 1))

    assert(weeks.all? { |week| week.length == 7 })
    assert_equal 1, weeks.first.first[:date].wday
    assert_equal 0, weeks.last.last[:date].wday
    assert_includes cells(weeks).map { |cell| cell[:date] }, Date.new(2026, 2, 1)
    assert_includes cells(weeks).map { |cell| cell[:date] }, Date.new(2026, 2, 28)
  end

  # February 2026 begins on a Sunday, so the first row is almost all January. Those days
  # are drawn rather than blanked, or a week that straddles the boundary stops reading
  # as a week, but they are marked so the month still stands out.
  it 'draws the neighbouring days but marks them as outside the month' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 2, 1))

    refute cell_on(weeks, Date.new(2026, 1, 30))[:in_month]
    assert cell_on(weeks, Date.new(2026, 2, 1))[:in_month]
  end
end

describe 'what a day carries' do
  include Rack::Test::Methods
  include CalendarData

  it 'puts a workout on the day it falls on' do
    sign_in
    on = Date.today
    id = a_workout(on:, lifted: true)

    cell = cell_on(Tectonic::Calendar.weeks(@account_id, Tectonic::Calendar.first_of(on)), on)

    assert_equal [id], cell[:workouts].map(&:id)
    assert_equal :performed, cell[:workouts].first.status
  end

  it "does not show another account's training" do
    sign_in
    mine = @account_id
    on = Date.today
    sign_in
    a_workout(on:, lifted: true)

    cell = cell_on(Tectonic::Calendar.weeks(mine, Tectonic::Calendar.first_of(on)), on)

    assert_empty cell[:workouts]
  end
end

describe 'a session that was written and not done' do
  include Rack::Test::Methods
  include CalendarData

  # The reason a calendar is worth drawing: a missed session is invisible in a list,
  # which only shows what is there, and the hole is the thing worth seeing.
  it 'is drawn as missed rather than left blank' do
    sign_in
    on = Date.today - 3
    a_workout(on:, lifted: false, planned: true)

    cell = cell_on(Tectonic::Calendar.weeks(@account_id, Tectonic::Calendar.first_of(on)), on)
    entry = Tectonic::Calendar.entries(cell[:workouts]).first

    assert_equal :skipped, entry[:status]
    assert_equal 'missed', entry[:word]
  end

  # A session still ahead of its date has not been missed, it just has not happened.
  it 'is still a plan while its date is ahead' do
    sign_in
    on = Date.today + 3
    a_workout(on:, lifted: false, planned: true)

    cell = cell_on(Tectonic::Calendar.weeks(@account_id, Tectonic::Calendar.first_of(on)), on)

    assert_equal 'planned', Tectonic::Calendar.entries(cell[:workouts]).first[:word]
  end
end

describe 'the month a page asks for' do
  include Rack::Test::Methods
  include CalendarData

  it 'reads a month it is given' do
    assert_equal Date.new(2026, 3, 1), Tectonic::Calendar.month_of('2026-03')
  end

  # The value reaches Date.new, so anything that is not a month is this month rather
  # than an argument error or a page a thousand years out.
  it 'falls back to this month for anything that is not one' do
    today = Date.new(2026, 8, 21)
    this_month = Date.new(2026, 8, 1)

    assert_equal this_month, Tectonic::Calendar.month_of(nil, today)
    assert_equal this_month, Tectonic::Calendar.month_of('nonsense', today)
    assert_equal this_month, Tectonic::Calendar.month_of('2026-13', today)
    assert_equal this_month, Tectonic::Calendar.month_of('99999-01', today)
    assert_equal this_month, Tectonic::Calendar.month_of('1900-01', today)
  end
end

describe 'the month tally' do
  include Rack::Test::Methods
  include CalendarData

  # Counted from the cells already drawn, and only for the month itself, so the days
  # spilling in from either side do not inflate it.
  it 'counts only the days inside the month' do
    sign_in
    inside = Tectonic::Calendar.first_of(Date.today) + 10
    a_workout(on: inside, lifted: true)
    a_workout(on: Tectonic::Calendar.first_of(Date.today) - 1, lifted: true)

    weeks = Tectonic::Calendar.weeks(@account_id, Tectonic::Calendar.first_of(Date.today))

    assert_equal({ performed: 1 }, Tectonic::Calendar.tally(weeks))
  end
end

describe 'the home page' do
  include Rack::Test::Methods
  include CalendarData

  it 'draws the calendar with a link to the session' do
    sign_in
    id = a_workout(on: Date.today, lifted: true)

    get '/'

    assert_equal 200, last_response.status
    assert_includes last_response.body, Date.today.strftime('%B %Y')
    assert_includes last_response.body, "/workouts/#{id}"
    assert_includes last_response.body, 'trained'
  end

  it 'moves to another month' do
    sign_in

    get '/', { month: '2026-03' }

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'March 2026'
    assert_includes last_response.body, 'Nothing trained or planned this month.'
  end

  it 'sends a signed-out visitor to the welcome page' do
    get '/'

    assert_equal 302, last_response.status
  end
end

