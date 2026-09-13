# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The charts had no text equivalent at all. #337, from the #328 audit.
#
# Five of them rendered as a bare <canvas> with no accessible name, no description and nothing
# beside it. WCAG 1.1.1 (level A) asks for a text alternative for non-text content, and a
# screen reader announced nothing -- not even that a chart was there. /volume is a page whose
# whole purpose is four charts, so to a reader it was four summary numbers followed by silence,
# with no indication that anything was missing.
#
# A table rather than an aria-label summarising the trend, which is what the issue asks for and
# is the split this project draws everywhere: a summary is the app deciding what the chart
# means, a table is the reader deciding.
module ChartAlternatives
  # A week of training, dated so it lands inside the default window.
  def trained(account_id, exercise, weight:, days_ago: 3)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today - days_ago)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, reps: 5, is_warmup: false,
                     is_completed: true, is_barbell: true, completed_at: Time.now)
  end

  def movement(account_id, name)
    Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: true)
  end

  def tables = last_response.body.scan('Show as a table').length

  # Only the tables this change owns. Chartkick serialises a BigDecimal into its own script
  # payload as the JSON string "0.125e4" -- Chart.js coerces that back to 1250 so the chart
  # draws correctly, and it is not what is under test here. Scanning the whole page would make
  # this assertion about somebody else's serialiser.
  def table_markup = last_response.body.scan(%r{<table.*?</table>}m).join

  # Every canvas Chartkick renders, and whether it is hidden from assistive technology.
  def exposed_canvases
    last_response.body.scan(/<div[^>]*>\s*<canvas|aria-hidden="true"><canvas/).length
  end
end

describe 'the volume page' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  before do
    @account_id = login
    squat = movement(@account_id, 'Squat')
    bench = movement(@account_id, 'Bench')
    trained(@account_id, squat, weight: 155)
    trained(@account_id, bench, weight: 95)
    get '/volume'
  end

  it 'renders' do
    assert_equal 200, last_response.status
  end

  # Four charts, four tables: weekly tonnage, weekly working sets, top set each week, and
  # working sets per lift.
  it 'offers a table beside every chart' do
    assert_equal 4, tables
  end

  it 'puts the numbers in the table, not only in the canvas' do
    assert_includes last_response.body, 'Weekly tonnage'
    assert_includes last_response.body, 'Working sets per lift'
  end
end

# How the two sit together: the canvas says nothing and the table says everything.
describe 'the chart and its table' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  before do
    @account_id = login
    trained(@account_id, movement(@account_id, 'Squat'), weight: 155)
    get '/volume'
  end

  # The canvas carries nothing the table does not, and an unlabelled canvas announced before
  # the table is furniture read aloud.
  it 'hides the canvases from a screen reader' do
    assert_includes last_response.body, 'aria-hidden="true"'
  end

  # Closed, so it is one line for everybody and the whole table for anybody who wants it.
  it 'keeps the tables closed by default' do
    refute_match(/<details[^>]*\sopen/, last_response.body)
  end

  # Not visually hidden: reading an exact value off a bar is guesswork for everybody, and
  # something on screen is something that gets noticed when it goes wrong.
  it 'puts the table on the page rather than hiding it from sight' do
    refute_match(/<details[^>]*class="[^"]*sr-only/, last_response.body)
  end
end

# The one chart with a line per lift. A two-column table cannot hold it: the question it
# answers is how several lifts moved against each other over the same weeks.
describe 'the top-set chart, which plots a series per lift' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  before do
    @account_id = login
    @squat = movement(@account_id, 'Squat')
    @bench = movement(@account_id, 'Bench')
    trained(@account_id, @squat, weight: 155)
    trained(@account_id, @bench, weight: 95)
    get '/volume'
  end

  # #256 in a new place. The weight columns are numeric(7,2), so Sequel hands back a
  # BigDecimal -- the chart escaped it because Chartkick serialises to JSON, and the table
  # printed 0.155e3, which is the correct rendering of a BigDecimal and no use to a lifter.
  # Caught by looking at the page rather than by any assertion, which is why there is one now.
  it 'writes a weight the way somebody would on a sheet' do
    assert_includes table_markup, '155'
    refute_match(/0\.\d+e\d/, table_markup)
  end

  it 'names every lift as a row' do
    assert_includes last_response.body, @squat.name
    assert_includes last_response.body, @bench.name
  end

  # A row per lift and a column per week, because that is the orientation that reads aloud
  # correctly: "Back Squat, 145, 150, 155" is the sentence somebody wants.
  it 'gives the lift column a row header' do
    assert_match(/<th scope="row"[^>]*>\s*#{Regexp.escape(@squat.name)}/, last_response.body)
  end
end

# The line chart skips the weeks a lift was not trained -- a week off squats is no tonnage but
# it is not a top set of zero -- so a cell with nothing in it is that same absence, said in
# words rather than as a dash a reader would have to interpret.
describe 'a lift that was not trained every week' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  it 'says so rather than printing a zero or a dash' do
    account_id = login
    squat = movement(account_id, 'Squat')
    bench = movement(account_id, 'Bench')
    trained(account_id, squat, weight: 155, days_ago: 3)
    trained(account_id, squat, weight: 160, days_ago: 10)
    trained(account_id, bench, weight: 95, days_ago: 3)
    get '/volume'

    assert_includes last_response.body, 'not trained'
  end
end

# The easy one, per the issue: the table of every set is already directly below, so a second
# table of the heaviest per day would be the same training said twice.
describe 'the chart on a movement page' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  before do
    @account_id = login
    @exercise = movement(@account_id, 'Squat')
    trained(@account_id, @exercise, weight: 155)
    get "/exercises/#{@exercise.id}/"
  end

  it 'hides its canvas rather than announcing an unlabelled graphic' do
    assert_includes last_response.body, 'aria-hidden="true"'
  end

  it 'points at the table that is already there' do
    assert_includes last_response.body, 'Every set is listed below'
  end

  it 'adds no second table of the same training' do
    assert_equal 0, tables
  end
end

# A page with nothing plotted draws no charts at all, so it should offer no tables either --
# an empty "Show as a table" is a control that opens onto nothing.
describe 'a volume page with nothing to plot' do
  include Rack::Test::Methods
  include RouteOwnership
  include ChartAlternatives

  it 'offers no tables, having no charts' do
    login
    get '/volume'

    assert_equal 0, tables
  end
end

