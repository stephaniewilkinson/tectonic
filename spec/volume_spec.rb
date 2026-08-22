# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'
require 'date'

# The aggregation is a module rather than SQL in a view precisely so it can be asserted
# directly, which is what most of this does. The two exclusions it turns on -- a warmup
# is not training, an unfinished set is a plan -- are the ones worth proving, because
# both are silent when they go wrong: the numbers stay plausible and only ever read high.
module VolumeData
  TOTALS = %i[sets reps tonnage].freeze

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

  def a_lift(name = "Lift #{SecureRandom.hex(4)}")
    DB[:exercises].insert(name:, account_id: @account_id)
  end

  # Weeks back from the Monday of this week, so a fixed date never drifts out of the
  # window the page asks for as the calendar moves.
  def monday(weeks_ago)
    today = Date.today
    (today - ((today.wday - 1) % 7)) - (weeks_ago * 7)
  end

  # `is_completed` rides in `flags` and is fetched rather than defaulted, so a spec can
  # pass an explicit nil -- which is the case a `!= false` check would let through.
  def log_set(exercise_id, on:, weight: 100, reps: 5, **flags)
    account_id = flags.fetch(:account_id, @account_id)
    at = Time.new(on.year, on.month, on.day, 18, 0)
    workout_id = DB[:workouts].where(account_id:, date: at).get(:id) ||
                 DB[:workouts].insert(account_id:, date: at)
    DB[:sets].insert(workout_id:, exercise_id:, weight:, reps:, **shape(flags))
  end

  # The flags a set carries beyond its load, defaulted here so a spec states only the one
  # it is about.
  def shape(flags)
    { measure: flags.fetch(:measure, 'reps'), duration_seconds: flags[:duration_seconds],
      is_per_side: flags.fetch(:is_per_side, false),
      is_warmup: flags.fetch(:is_warmup, false),
      is_completed: flags.fetch(:is_completed, true) }
  end

  def totals_of(rows)
    rows.slice(*VolumeData::TOTALS)
  end

  def last_week_of(...)
    totals_of(Tectonic::Volume.weekly(...).last)
  end
end

describe 'weekly volume' do
  include Rack::Test::Methods
  include VolumeData

  # Tonnage is weight times reps summed, over the sets that were actually worked.
  it 'sums sets, reps and tonnage a week at a time' do
    sign_in
    lift = a_lift
    log_set lift, weight: 100, reps: 5, on: monday(1)
    log_set lift, weight: 200, reps: 3, on: monday(1)
    log_set lift, weight: 150, reps: 2, on: monday(0)

    rows = Tectonic::Volume.weekly(@account_id)

    assert_equal({ sets: 2, reps: 8, tonnage: 1100 }, totals_of(rows[-2]))
    assert_equal({ sets: 1, reps: 2, tonnage: 300 }, totals_of(rows[-1]))
  end
end

describe 'what counts as work' do
  include Rack::Test::Methods
  include VolumeData

  # The ramp up to a working weight is not work. Counting it would let somebody raise
  # their tonnage by warming up more carefully.
  it 'leaves warmups out' do
    sign_in
    lift = a_lift
    log_set lift, weight: 45, reps: 10, on: monday(0), is_warmup: true
    log_set lift, weight: 225, reps: 5, on: monday(0)

    assert_equal({ sets: 1, reps: 5, tonnage: 1125 }, last_week_of(@account_id))
  end

  # A generated session is a whole block of rows written ahead of time, none of them
  # done. Counting those would credit a lifter for training they have not done, and
  # would flatter them more the further ahead they planned.
  it 'counts what was completed, not what was planned' do
    sign_in
    lift = a_lift
    log_set lift, weight: 100, reps: 5, on: monday(0)
    log_set lift, weight: 500, reps: 5, on: monday(0), is_completed: false
    log_set lift, weight: 900, reps: 5, on: monday(0), is_completed: nil

    assert_equal({ sets: 1, reps: 5, tonnage: 500 }, last_week_of(@account_id))
  end
end

# A count taken per side is half the work that happened: 3x8 per side is 48 reps of work,
# not 24. Summing the stored number is what made unilateral training read as half itself.
describe 'work counted per side' do
  include Rack::Test::Methods
  include VolumeData

  it 'counts the reps that were actually done' do
    sign_in
    log_set a_lift, weight: 50, reps: 8, on: monday(0), is_per_side: true

    assert_equal({ sets: 1, reps: 16, tonnage: 800 }, last_week_of(@account_id))
  end

  it 'leaves a two-sided count alone' do
    sign_in
    log_set a_lift, weight: 50, reps: 8, on: monday(0)

    assert_equal({ sets: 1, reps: 8, tonnage: 400 }, last_week_of(@account_id))
  end
end

# A plank and a set of squats are both training and neither converts into the other, so
# seconds are summed apart from reps rather than added into them.
describe 'work counted in time' do
  include Rack::Test::Methods
  include VolumeData

  it 'contributes its seconds, and no reps or tonnage' do
    sign_in
    log_set a_lift, on: monday(0), measure: 'time', duration_seconds: 60, reps: nil, weight: nil

    week = Tectonic::Volume.weekly(@account_id).last

    assert_equal 60, week[:seconds]
    assert_nil week[:reps]
    assert_nil week[:tonnage]
  end
end

describe 'a week off' do
  include Rack::Test::Methods
  include VolumeData

  # A week off is really no volume, and that is the whole question the page answers, so
  # the empty week has to be drawn rather than closed up.
  it 'is filled with a zero rather than closing the gap' do
    sign_in
    lift = a_lift
    log_set lift, weight: 100, reps: 5, on: monday(2)
    log_set lift, weight: 100, reps: 5, on: monday(0)

    rows = Tectonic::Volume.weekly(@account_id)

    assert_equal 3, rows.length
    assert_equal 0, rows[1][:sets]
    assert_equal 0, rows[1][:tonnage]
    assert_equal 2, Tectonic::Volume.summary(rows)[:weeks]
  end
end

describe 'narrowing volume' do
  include Rack::Test::Methods
  include VolumeData

  it 'narrows to one lift' do
    sign_in
    squat = a_lift 'Squat'
    bench = a_lift 'Bench'
    log_set squat, weight: 300, reps: 5, on: monday(0)
    log_set bench, weight: 100, reps: 5, on: monday(0)

    assert_equal 1500, Tectonic::Volume.weekly(@account_id, exercise_id: squat).last[:tonnage]
    assert_equal 500, Tectonic::Volume.weekly(@account_id, exercise_id: bench).last[:tonnage]
  end

  # The window is a bound on the query, not just on the chart.
  it 'ignores work older than the window' do
    sign_in
    lift = a_lift
    log_set lift, weight: 100, reps: 5, on: monday(20)
    log_set lift, weight: 100, reps: 5, on: monday(1)

    assert_equal 500, Tectonic::Volume.summary(Tectonic::Volume.weekly(@account_id, weeks: 12))[:tonnage]
    assert_equal 1000, Tectonic::Volume.summary(Tectonic::Volume.weekly(@account_id, weeks: 26))[:tonnage]
  end
end

describe 'volume across accounts' do
  include Rack::Test::Methods
  include VolumeData

  # Exercises are shared across accounts, so the account filter has to sit on the
  # workout rather than on the lift.
  it "does not count another account's sets against the same lift" do
    sign_in
    lift = a_lift
    mine = @account_id
    log_set lift, weight: 100, reps: 5, on: monday(0)
    sign_in
    log_set lift, weight: 999, reps: 5, on: monday(0)

    assert_equal 500, Tectonic::Volume.summary(Tectonic::Volume.weekly(mine))[:tonnage]
  end
end

describe 'the top set trend' do
  include Rack::Test::Methods
  include VolumeData

  # Intensity is a separate question from volume: this is the heaviest thing lifted,
  # not how much was lifted.
  it 'plots the heaviest completed set of each week, per lift' do
    sign_in
    squat = a_lift 'Squat'
    log_set squat, weight: 185, reps: 5, on: monday(1)
    log_set squat, weight: 225, reps: 3, on: monday(1)
    log_set squat, weight: 235, reps: 1, on: monday(0)

    name, weeks = Tectonic::Volume.top_sets(@account_id).first

    assert_equal 'Squat', name
    assert_equal [225, 235], weeks.values
  end
end

describe 'a lift left alone for a month' do
  include Rack::Test::Methods
  include VolumeData

  # The counterpart of the zero-filling above, and the reason the two charts differ: a
  # week without squats is no tonnage, but it is not a top set of zero, and drawing one
  # would show a dip to the floor that nobody lifted.
  it 'is skipped rather than drawn as a zero' do
    sign_in
    squat = a_lift 'Squat'
    log_set squat, weight: 185, reps: 5, on: monday(3)
    log_set squat, weight: 205, reps: 5, on: monday(0)

    _name, weeks = Tectonic::Volume.top_sets(@account_id).first

    assert_equal 2, weeks.length
    assert_equal [185, 205], weeks.values
    refute_includes weeks.values, 0
  end
end

describe 'the window on the trend' do
  include Rack::Test::Methods
  include VolumeData

  # The window has to be asserted here rather than only against weekly totals: those
  # clamp their own span to the window and so stay right even if the query stops
  # bounding itself, which hides the bound going missing. These two have no such
  # backstop, and a year of old training would quietly walk back into both.
  it 'bounds the trend and the per-lift totals' do
    sign_in
    lift = a_lift 'Squat'
    log_set lift, weight: 185, reps: 5, on: monday(20)
    log_set lift, weight: 205, reps: 5, on: monday(1)

    assert_equal [205], Tectonic::Volume.top_sets(@account_id, weeks: 12).first.last.values
    assert_equal [185, 205], Tectonic::Volume.top_sets(@account_id, weeks: 26).first.last.values
    assert_equal [['Squat', 1]], Tectonic::Volume.by_exercise(@account_id, weeks: 12)
    assert_equal [['Squat', 2]], Tectonic::Volume.by_exercise(@account_id, weeks: 26)
  end
end

describe 'the order lifts are drawn in' do
  include Rack::Test::Methods
  include VolumeData

  it 'puts the most-trained lift first, so a chart takes the ones that matter' do
    sign_in
    squat = a_lift 'Squat'
    curl = a_lift 'Curl'
    3.times { log_set squat, weight: 300, reps: 5, on: monday(0) }
    log_set curl, weight: 30, reps: 10, on: monday(0)

    assert_equal %w[Squat Curl], Tectonic::Volume.top_sets(@account_id).map(&:first)
    assert_equal [['Squat', 3], ['Curl', 1]], Tectonic::Volume.by_exercise(@account_id)
  end
end

describe 'the volume page' do
  include Rack::Test::Methods
  include VolumeData

  it 'charts the work and is linked from the nav' do
    sign_in
    log_set a_lift('Squat'), weight: 225, reps: 5, on: monday(0)

    get '/volume'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Weekly tonnage'
    assert_includes last_response.body, 'new Chartkick["ColumnChart"]'
    assert_includes last_response.body, '1125'
    assert_includes last_response.body, 'href="/volume"'
  end
end

describe 'the lift filter' do
  include Rack::Test::Methods
  include VolumeData

  # The library ships movements this account has never trained, and a personal lift can
  # share a name with a library one -- two identical options whose ids differ, where
  # picking the wrong one silently draws an empty page.
  it 'offers only lifts with work in the window' do
    sign_in
    trained = a_lift 'Squat'
    a_lift 'Never Done'
    log_set trained, weight: 225, reps: 5, on: monday(0)

    assert_equal [[trained, 'Squat']], Tectonic::Volume.lifts(@account_id)
  end

  it 'drops a lift that falls out of the window' do
    sign_in
    old = a_lift 'Old Lift'
    log_set old, weight: 100, reps: 5, on: monday(20)

    assert_empty Tectonic::Volume.lifts(@account_id, weeks: 12)
    assert_equal [[old, 'Old Lift']], Tectonic::Volume.lifts(@account_id, weeks: 26)
  end
end

describe 'the chart palette' do
  # The intensity chart is the first in the app to draw more than one series, and
  # Chart.js colours anything past the end of the palette in its own grey -- which drew
  # two lifts the same colour and left the legend unable to tell them apart.
  it 'has a colour for every line the trend will draw' do
    assert_operator Tectonic::CHART_COLORS.length, :>=, Tectonic::Volume::SERIES
    assert_equal Tectonic::CHART_COLORS.length, Tectonic::CHART_COLORS.uniq.length
  end
end

describe 'the volume page with nothing to draw' do
  include Rack::Test::Methods
  include VolumeData

  # A page with nothing to plot should not pull down a quarter of a megabyte of
  # charting library to draw an empty axis.
  it 'draws no chart and loads no charting library' do
    sign_in
    log_set a_lift, weight: 225, reps: 5, on: monday(0), is_completed: false

    get '/volume'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'No completed working sets'
    refute_includes last_response.body, 'chartkick.js'
  end
end

describe 'the volume window in the query string' do
  include Rack::Test::Methods
  include VolumeData

  # The window reaches a date subtraction, so it is chosen from the offered list rather
  # than taken from the query string.
  it 'falls back to the default when handed something that is not one' do
    sign_in

    get '/volume', { weeks: '99999' }

    assert_equal 200, last_response.status
    assert_includes last_response.body, "last #{Tectonic::Volume::DEFAULT_WEEKS} weeks"
  end

  it 'requires a login' do
    get '/volume'

    assert_equal 302, last_response.status
  end
end

