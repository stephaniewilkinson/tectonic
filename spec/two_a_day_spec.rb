# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/exercise_library'
require_relative '../lib/tectonic/program_generator'
require 'rack/test'
require 'bcrypt'
require 'securerandom'
require 'date'

# The set-logging specs below need a movement the account may select, and the library is
# where one comes from. Seeded here rather than relied on, because several other spec
# files seed it too and a run of this file on its own would otherwise find an empty
# library, post a set with a blank exercise_id, and be redirected without one being
# written -- three failures whose cause is the order the suite happened to load in.
Tectonic::Exercise.load_library

# A lift in the morning and a walk in the evening. Two sessions on one date already
# work, and they work by accident of three separate decisions taken for other reasons:
# workouts carries no unique index on (account_id, date), the calendar groups a day's
# rows rather than taking one of them, and the generator keys idempotency on the program
# day instead of on the date it computes. Nothing asserted any of the three, so each was
# a change away from being undone by something that would have looked local and correct
# -- an index added to speed a lookup, a `first` where a list was meant. These drive the
# real routes so that the day one of them goes, something says so.
module TwoADay
  def app
    Tectonic.app
  end

  def login
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    @account_id = DB[:accounts].where(email:).get(:id)
  end

  # The CSRF token a form on `page` carries, picked out by the action it posts to. The
  # token is bound to that path, and the workouts list carries one delete form per row,
  # so taking the first token on the page is how a test posts a valid token at the wrong
  # route and reads back a 403 it then has to explain.
  def token_for(page, action = page)
    get page
    last_response.body[/action="#{Regexp.escape(action)}"[^>]*>.*?name="_csrf"[^>]*value="([^"]*)"/m, 1]
  end

  # The new-workout form as it actually posts: an empty id, which is what tells the route
  # this is a new session rather than a reschedule of one, and a bare %m/%d/%Y date.
  def create_workout(on)
    post '/workouts', { 'id' => '', 'date' => on.strftime('%m/%d/%Y'),
                        '_csrf' => token_for('/workouts/new', '/workouts') }
    last_response.headers['location'][%r{/workouts/(\d+)/}, 1].to_i
  end

  def two_sessions_today
    login
    @morning = create_workout(Date.today)
    @evening = create_workout(Date.today)
  end

  def library_lift
    DB[:exercises].where(account_id: nil).get(:id)
  end

  def log_set(workout, exercise_id, weight)
    post "/workouts/#{workout}/sets/new",
         { 'weight' => weight.to_s, 'reps' => '5', 'exercise_id' => exercise_id.to_s,
           '_csrf' => token_for("/workouts/#{workout}/sets/new") }
  end
end

describe 'two sessions logged on one date' do
  include Rack::Test::Methods
  include TwoADay

  before { two_sessions_today }

  it 'keeps them as two rows rather than folding the second into the first' do
    refute_equal @morning, @evening
    assert_equal 2, DB[:workouts].where(account_id: @account_id).count
  end

  # Both land at midnight, because the form posts a date with no time of day in it. So
  # the id is the only thing that says which was the morning session, and the id is not
  # shown anywhere a lifter reads.
  it 'stores both at the same instant, leaving the id to order them' do
    stamps = DB[:workouts].where(account_id: @account_id).order(:id).select_map(:date)
    times_of_day = stamps.map { |stamp| [stamp.hour, stamp.min] }

    assert_equal [Date.today, Date.today], stamps.map(&:to_date)
    assert_equal [[0, 0], [0, 0]], times_of_day
  end
end

describe 'the workouts list on a day trained twice' do
  include Rack::Test::Methods
  include TwoADay

  before { two_sessions_today }

  it 'gives each session a row of its own' do
    get '/workouts'

    assert_includes last_response.body, "/workouts/#{@morning}/"
    assert_includes last_response.body, "/workouts/#{@evening}/"
  end

  # The two rows are the same date and nothing else, which is the substance of what is
  # still awkward here: a workout has no name, so the list cannot say which is which.
  it 'writes the same date on both rows' do
    get '/workouts'

    assert_equal 2, last_response.body.scan(Date.today.strftime('%b %d, %Y')).length
  end
end

describe 'the calendar cell for a day trained twice' do
  include Rack::Test::Methods
  include TwoADay

  before { two_sessions_today }

  it 'holds both sessions in the one day' do
    weeks = Tectonic::Calendar.weeks(@account_id, Tectonic::Calendar.first_of(Date.today))
    cell = weeks.flatten.find { |day| day[:date] == Date.today }

    assert_equal [@morning, @evening], cell[:workouts].map(&:id).sort
    assert_equal 2, Tectonic::Calendar.entries(cell[:workouts]).length
  end

  it 'draws a link to each of them on the home page' do
    get '/'

    assert_includes last_response.body, %(href="/workouts/#{@morning}")
    assert_includes last_response.body, %(href="/workouts/#{@evening}")
  end
end

describe 'sets logged against a day with two sessions' do
  include Rack::Test::Methods
  include TwoADay

  before { two_sessions_today }

  it 'lands each set on the session it was logged through' do
    log_set(@morning, library_lift, 135)
    log_set(@evening, library_lift, 95)

    assert_equal [135], DB[:sets].where(workout_id: @morning).select_map(:weight)
    assert_equal [95], DB[:sets].where(workout_id: @evening).select_map(:weight)
  end

  # Each session opens on a page of its own, showing its own work. The set is matched by
  # the link its row carries rather than by the weight printed in it, which a page is
  # free to contain for a dozen unrelated reasons -- an id, a class, a path in an icon.
  it 'opens each session on a page showing only its own sets' do
    log_set(@morning, library_lift, 135)
    lifted = DB[:sets].where(workout_id: @morning).get(:id)

    get "/workouts/#{@morning}/"
    assert_includes last_response.body, "/sets/#{lifted}"

    get "/workouts/#{@evening}/"
    assert_equal 200, last_response.status
    refute_includes last_response.body, "/sets/#{lifted}"
  end
end

describe "editing one of a day's two sessions" do
  include Rack::Test::Methods
  include TwoADay

  before { two_sessions_today }

  # Rescheduling posts back to /workouts with the id filled in, which is the same route
  # that creates one. Moving the evening session must not take the morning one with it.
  #
  # The date is the second of the second because that day reads the same whichever way
  # round the two numbers are taken, and the two branches of this one route do not take
  # them the same way. Creating hands the string to Postgres, which is month-first, so
  # 01/02/2030 is January 2; rescheduling assigns it to the model, which typecasts it in
  # Ruby, and Ruby reads it day-first as February 1. That disagreement is real and it is
  # not this test's business, so this picks a date it cannot turn on.
  it 'moves only the session that was edited' do
    post '/workouts', { 'id' => @evening.to_s, 'date' => '02/02/2030',
                        '_csrf' => token_for('/workouts/new', '/workouts') }

    assert_equal Date.new(2030, 2, 2), DB[:workouts].where(id: @evening).get(:date).to_date
    assert_equal Date.today, DB[:workouts].where(id: @morning).get(:date).to_date
  end
end

describe "deleting one of a day's two sessions" do
  include Rack::Test::Methods
  include TwoADay

  before do
    two_sessions_today
    log_set(@evening, library_lift, 95)
  end

  it 'leaves the other session and its sets standing' do
    post "/workouts/#{@morning}/delete",
         { '_csrf' => token_for('/workouts', "/workouts/#{@morning}/delete") }

    assert_equal 0, DB[:workouts].where(id: @morning).count
    assert_equal 1, DB[:workouts].where(id: @evening).count
    assert_equal 1, DB[:sets].where(workout_id: @evening).count
  end
end

# Two program days on one weekday: the squat rack in the morning, a walk in the evening,
# both written for the Monday. program_days has no unique index on (program_week_id,
# weekday) either, and the generator asks the day, not the date, whether it has already
# written a session -- which is what makes both of these true at once.
#
# A module rather than two bare defs at the top of the file, which land on Object and are
# then visible to every other spec in the run; "monday_of" is exactly the name a second
# file would reach for and get this one's meaning instead.
module TwoDayWeek
  # 2026-08-16 is a Sunday, so this week's Monday -- the date both days resolve to
  # through ProgramWeek#date_for -- is 2026-08-17.
  START_DATE = Date.new(2026, 8, 16)
  MONDAY = Date.new(2026, 8, 17)

  def two_day_program
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise_id = Tectonic::Exercise.insert(account_id:, name: 'Back Squat')
    program = Tectonic::Program.create(account_id:, name: "P#{SecureRandom.hex(4)}", block: 0,
                                       start_date: START_DATE, preferred_reps: 5, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    %w[Squat Walk].each { |focus| monday_of(week, exercise_id, focus) }
    program
  end

  def monday_of(week, exercise_id, focus)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1, focus:)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 0, sets: 3,
                                 reps: 5, top_weight: 135, is_barbell: true, is_main: true)
  end
end

describe 'a written week with two days on the same weekday' do
  include TwoDayWeek

  it 'writes a session for each of them on that date' do
    workouts = Tectonic::ProgramGenerator.new(two_day_program).generate(1)
    dates = workouts.map { |workout| workout.date.to_date }

    assert_equal 2, workouts.map(&:id).uniq.length
    assert_equal [TwoDayWeek::MONDAY] * 2, dates
  end

  it 'stays idempotent: generating the week again makes no third session' do
    program = two_day_program
    generator = Tectonic::ProgramGenerator.new(program)
    first = generator.generate(1).map(&:id).sort

    assert_equal first, generator.generate(1).map(&:id).sort
    assert_equal 2, Tectonic::Workout.where(account_id: program.account_id).count
  end
end

describe 'what the two generated sessions carry' do
  include TwoDayWeek

  # The plan knows perfectly well which is which -- the program day it came from has a
  # focus, 'Squat' or 'Walk' -- and the session it writes keeps none of it, because a
  # workout has no column to put it in. Every column a person reads is identical, which
  # is the argument for a nullable name on workouts defaulted from the day's focus.
  it 'differs in nothing a lifter can see' do
    sessions = Tectonic::ProgramGenerator.new(two_day_program).generate(1).sort_by(&:id)
    first, second = sessions
    ignored = %i[id program_day_id created_on created_at]

    assert_equal %w[Squat Walk], sessions.map { |session| session.program_day.focus }.sort
    assert_equal first.values.except(*ignored), second.values.except(*ignored)
  end
end

# The one caller that cannot open a second session on a day, and the one most likely to
# be asked to: create_workout is find-or-create on the calendar date by construction, so
# an assistant told "log my evening walk" is handed back the morning session and logs
# into that. The idempotency is deliberate and worth keeping -- it is what stops a model
# stranding an empty workout every time it reaches for one -- but it has no way to say
# "another one, please", so the evening walk joins the morning lift.
describe 'opening a second session on a day over MCP' do
  include Rack::Test::Methods

  it 'hands back the session already on that date rather than opening another' do
    token = mint(scopes: ['write'])
    morning = Tectonic::Workout.create(account_id: token.account_id, date: Date.new(2027, 7, 7))

    call_tool('create_workout', raw: token.raw, arguments: { date: '2027-07-07' })

    assert_equal morning.id, tool_result['structuredContent']['id']
    assert_equal 1, Tectonic::Workout.where(account_id: token.account_id).count
  end

  it 'lands an evening set on the session already there' do
    token = mint(scopes: ['write'])
    morning = Tectonic::Workout.create(account_id: token.account_id, date: Date.new(2027, 7, 8))

    call_tool('create_set', raw: token.raw,
                            arguments: { exercise: 'Walk', date: '2027-07-08', weight: 0, reps: 1 })

    assert_equal morning.id, Tectonic::Set[tool_result['structuredContent']['id']].workout_id
  end
end

