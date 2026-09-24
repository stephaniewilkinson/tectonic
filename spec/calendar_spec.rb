# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'
require 'date'

# The grid is a module so the month arithmetic can be asserted without a browser: whole
# weeks, Sunday first, and the neighbouring days drawn but marked as outside the month.
# The status a cell carries is the one a workout already answers with, so what matters
# here is that the calendar reads it rather than inventing a second set of rules.
module CalendarData
  def app
    Tectonic.app
  end

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password))
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

  # Whole weeks, so every row has seven days and the grid is rectangular. wday 0 is
  # Sunday and 6 is Saturday, which is the pair the header labels are printed in.
  it 'covers the month in whole weeks beginning on Sunday' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 8, 1))

    assert(weeks.all? { |week| week.length == 7 })
    assert_equal 0, weeks.first.first[:date].wday
    assert_equal 6, weeks.last.last[:date].wday
    assert_includes cells(weeks).map { |cell| cell[:date] }, Date.new(2026, 8, 1)
    assert_includes cells(weeks).map { |cell| cell[:date] }, Date.new(2026, 8, 31)
  end

  # The labels are what the columns are read by, so they have to be in the order the days
  # come out in rather than merely be the seven names.
  it 'labels the columns in the order the days fall' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 8, 1))
    labels = weeks.first.map { |cell| cell[:date].strftime('%a') }

    assert_equal Tectonic::Calendar::DAY_NAMES, labels
  end

  # August 2026 begins on a Saturday, so the first row is almost all July. Those days are
  # drawn rather than blanked, or a week that straddles the boundary stops reading as a
  # week, but they are marked so the month still stands out.
  it 'draws the neighbouring days but marks them as outside the month' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 8, 1))

    refute cell_on(weeks, Date.new(2026, 7, 31))[:in_month]
    assert cell_on(weeks, Date.new(2026, 8, 1))[:in_month]
  end
end

# `weeks` slices the range by seven and trusts `bounds` to have returned a whole number of
# them. The months that would show that trust misplaced are the ones already flush with a
# week at one end or both, where the grid has nothing to add there and an off-by-one has
# nowhere to hide but the last row.
describe 'a month already flush with the week' do
  include Rack::Test::Methods
  include CalendarData

  # February 2026 opens on a Sunday and closes on a Saturday: four rows, and not one day
  # of January or March in the grid.
  it 'adds nothing to a month that starts on Sunday and ends on Saturday' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 2, 1))

    assert_equal 4, weeks.length
    assert_equal Date.new(2026, 2, 1), weeks.first.first[:date]
    assert_equal Date.new(2026, 2, 28), weeks.last.last[:date]
    assert(cells(weeks).all? { |cell| cell[:in_month] })
  end

  # March 2026 opens on a Sunday and closes on a Tuesday, so it spills forward only.
  it 'spills forward from a month that starts on Sunday' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 3, 1))

    assert_equal 5, weeks.length
    assert_equal Date.new(2026, 3, 1), weeks.first.first[:date]
    assert_equal Date.new(2026, 4, 4), weeks.last.last[:date]
  end

  # October 2026 is the mirror: it opens on a Thursday and closes on a Saturday.
  it 'spills backward from a month that ends on Saturday' do
    sign_in
    weeks = Tectonic::Calendar.weeks(@account_id, Date.new(2026, 10, 1))

    assert_equal 5, weeks.length
    assert_equal Date.new(2026, 9, 27), weeks.first.first[:date]
    assert_equal Date.new(2026, 10, 31), weeks.last.last[:date]
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
    # An account with nothing in it at all is pointed at Start here rather than told the month
    # was quiet (#636); a quiet month on an account that has trained is pinned in
    # an_account_with_nothing_in_it_yet_spec.
    assert_includes last_response.body, 'Nothing logged or planned yet.'
  end

  it 'sends a signed-out visitor to the welcome page' do
    get '/'

    assert_equal 302, last_response.status
  end
end

describe 'what an entry says' do
  include Rack::Test::Methods
  include CalendarData

  # It used to say nothing at all below sm, on the reasoning that seven columns at phone
  # width leave no room for the word. #492 is the screenshot of what that produces: five rows
  # of empty coloured boxes, which reads as a page that failed to render rather than as a
  # deliberate minimum. The text is drawn at every width now and truncates where it must.
  #
  # The word has to survive somewhere a screen reader still finds it either way: the title
  # attribute this replaced was never reachable by a thumb, and deleting the word outright
  # would leave the link with nothing to be announced as but its href.
  #
  # Two spans rather than one since #143. The chip shows a session's name where it has one,
  # so what is read and what is drawn are no longer the same string, and the visible half is
  # aria-hidden to keep a named session from being announced twice over.
  it 'keeps the word in the markup for a reader that cannot see the colour' do
    sign_in
    a_workout(on: Date.today, lifted: true)

    get '/'

    assert_includes last_response.body, '<span class="sr-only">trained</span>'
  end

  # A session with no name and no program day behind it, which is every session logged
  # before #143: the chip goes on showing what it always showed.
  it 'still draws the word itself when there is no name to draw instead' do
    sign_in
    a_workout(on: Date.today, lifted: true)

    get '/'

    assert_includes last_response.body, '<span class="truncate" aria-hidden="true">trained</span>'
  end

  # The bug itself, as a property rather than as a class list: nothing on this chip may be
  # hidden at a width somebody actually holds. #492.
  it 'draws it on a phone and not only on a desktop' do
    sign_in
    a_workout(on: Date.today, lifted: true)

    get '/'

    # The visible span's own classes, split into utilities. Matching on the chip as a string
    # is not enough: `aria-hidden="true"` contains the word, so a substring check passes for
    # the wrong reason and would go on passing if `hidden` came back.
    chip = last_response.body[%r{<a href="/workouts/\d+".*?</a>}m]
    drawn = chip[/<span class="([^"]*)" aria-hidden/, 1].to_s.split

    refute_includes drawn, 'hidden'
    refute_includes drawn, 'sm:inline'
  end
end

