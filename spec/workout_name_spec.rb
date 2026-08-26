# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# Telling two sessions on one date apart. #89 asked for two workouts a day and #133 proved
# they already work end to end; what neither gave anybody is a way to say which is which.
# The morning lift and the evening walk rendered as the same word twice in one calendar
# cell and the same date twice in the list, and opening both was the only way to find out.
module WorkoutName
  def two_sessions_today(account_id, first:, second:)
    day = Date.today
    [first, second].map { |name| Tectonic::Workout.create(account_id:, date: day, name:).id }
  end
end

describe 'what a workout is called' do
  include Rack::Test::Methods
  include RouteOwnership
  include WorkoutName

  before { @account_id = login }

  # A text input posts an empty string whether or not anybody typed in it, and '' is
  # truthy, so a blank stored as itself would draw an empty element beside every date.
  it 'is nothing at all rather than an empty string when nobody typed one' do
    assert_nil Tectonic::Workout.clean_name('')
    assert_nil Tectonic::Workout.clean_name('   ')
    assert_nil Tectonic::Workout.clean_name(nil)
    assert_equal 'Morning lift', Tectonic::Workout.clean_name('  Morning lift  ')
  end

  it 'is saved off the form, and cleared by clearing the field' do
    post '/workouts', { date: Date.today.strftime('%m/%d/%Y'), name: '  Evening walk  ', id: '',
                        '_csrf' => token_for('/workouts/new') }
    workout = Tectonic::Workout.where(account_id: @account_id).order(:id).last

    assert_equal 'Evening walk', workout.name

    post '/workouts', { date: Date.today.strftime('%m/%d/%Y'), name: '  ', id: workout.id.to_s,
                        '_csrf' => token_for('/workouts/new') }

    assert_nil workout.refresh.name
  end
end

describe 'two sessions on one date' do
  include Rack::Test::Methods
  include RouteOwnership
  include WorkoutName

  before do
    @account_id = login
    two_sessions_today(@account_id, first: 'Morning lift', second: 'Evening walk')
  end

  # The calendar cell. Both chips used to read "planned", one above the other.
  it 'are told apart in the calendar cell they share' do
    get '/'

    assert_includes last_response.body, 'Morning lift'
    assert_includes last_response.body, 'Evening walk'
  end

  # The list. Both rows used to read the same date and nothing else.
  it 'are told apart in the list' do
    get '/workouts'

    assert_includes last_response.body, 'Morning lift'
    assert_includes last_response.body, 'Evening walk'
  end
end

# A generated session gets its name for free from the program day that wrote it, which is
# what makes this arrive populated for anybody running a block rather than empty for
# everybody. Read through rather than copied at generation, so renaming a day renames the
# sessions it has already written.
describe 'a session a program wrote' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    program = Tectonic::Program.create(account_id: @account_id, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    @day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday, focus: 'Squat day')
    @workout = Tectonic::Workout.create(account_id: @account_id, date: Date.today, program_day_id: @day.id)
  end

  it 'takes the focus of the day that wrote it, without being given a name' do
    assert_nil @workout.name
    assert_equal 'Squat day', @workout.label
  end

  it 'follows the day when the day is renamed' do
    @day.update(focus: 'Lower body')

    assert_equal 'Lower body', @workout.refresh.label
  end

  # A session that wants to disagree with its day says so, and what it says wins.
  it 'is overridden by a name of its own' do
    @workout.update(name: 'Squat day, but light')

    assert_equal 'Squat day, but light', @workout.label
  end
end

# Every session logged before this existed has neither, and has to go on rendering.
describe 'a session with neither a name nor a program day' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'has no label, and the pages that show one still render' do
    account_id = login
    workout = Tectonic::Workout.create(account_id:, date: Date.today)

    assert_nil workout.label

    get '/'

    assert_equal 200, last_response.status

    get '/workouts'

    assert_equal 200, last_response.status
  end
end

