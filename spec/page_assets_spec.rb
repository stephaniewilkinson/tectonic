# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# What each page actually loads, asserted against the rendered HTML rather than against
# the layout's good intentions. Chart.js and Chartkick are roughly half a megabyte and
# used to be in the head of every page in the app, including the two forms a visitor
# meets before they have logged a single set. The rule now is that they follow a chart,
# so these specs name the pages that draw one and the pages that do not.
module PageAssets
  CHART_SCRIPTS = ['/js/chart.umd.js', '/js/chartkick.js'].freeze
  # Vendored for a time axis, which nothing in the app draws, so no page should carry it.
  DATE_ADAPTER = '/js/chartjs-adapter-date-fns.bundle.js'

  def app
    Tectonic.app
  end

  def refute_chart_scripts
    CHART_SCRIPTS.each { |script| refute_includes last_response.body, script }
  end

  def make_account
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    [email, password]
  end

  # A signed-in account with a lift of its own and a workout to log it into.
  def sign_in_with_a_lift
    email, password = make_account
    get '/login'
    post '/login', { login: email, password:, '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    account_id = DB[:accounts].where(email:).get(:id)
    @exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    @workout_id = DB[:workouts].insert(account_id:, date: Time.now)
  end

  def log_set(weight, is_warmup: false)
    DB[:sets].insert(workout_id: @workout_id, exercise_id: @exercise_id, weight:, reps: 5,
                     is_warmup:, is_completed: true)
  end
end

describe 'a page with no chart on it' do
  include Rack::Test::Methods
  include PageAssets

  it 'leaves the charting libraries off the front page and both auth forms' do
    ['/welcome', '/login', '/create-account'].each do |path|
      get path

      assert_equal 200, last_response.status
      refute_chart_scripts
    end
  end

  it 'leaves them off an exercise with nothing to chart but keeps the page' do
    sign_in_with_a_lift
    log_set 45, is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_includes last_response.body, '45'
    refute_chart_scripts
  end
end

describe 'the exercise page with a histogram on it' do
  include Rack::Test::Methods
  include PageAssets

  before do
    sign_in_with_a_lift
    log_set 135
    get "/exercises/#{@exercise_id}"
  end

  # Chartkick adapts Chart.js, so the library it adapts has to be the one named first.
  it 'loads Chart.js and then Chartkick, and nothing else does' do
    body = last_response.body

    assert_includes body, PageAssets::CHART_SCRIPTS.first
    assert_includes body, PageAssets::CHART_SCRIPTS.last
    assert_operator body.index(PageAssets::CHART_SCRIPTS.first), :<, body.index(PageAssets::CHART_SCRIPTS.last)
  end

  it 'still hands the chart its counts' do
    assert_includes last_response.body, 'new Chartkick["ColumnChart"]'
  end

  it 'carries no date adapter, there being no time axis to give one to' do
    refute_includes last_response.body, PageAssets::DATE_ADAPTER
  end
end

