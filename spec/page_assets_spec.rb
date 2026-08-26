# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# What each page actually loads, asserted against the rendered HTML rather than against
# the layout's good intentions. A quarter of a megabyte of charting used to sit in the
# head of every page in the app, including the two forms a visitor meets before they have
# logged a single set. The rule now is that it follows a chart, so these specs name the
# pages that draw one and the pages that do not.
module PageAssets
  # In dependency order: Chart.js, then Chartkick, which adapts it.
  CHART_SCRIPTS = ['/js/chart.umd.js', '/js/chartkick.js'].freeze
  # Vendored, and loaded by nothing. It exists to give Chart.js a time axis, and the one
  # chart in the app spaces its days evenly rather than by the calendar, so no page has a
  # date for it to parse. Asserted so that it cannot drift back into the layout unnoticed.
  DATE_ADAPTER = '/js/chartjs-adapter-date-fns.bundle.js'

  def app
    Tectonic.app
  end

  def refute_chart_scripts
    (CHART_SCRIPTS + [DATE_ADAPTER]).each { |script| refute_includes last_response.body, script }
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

describe 'the exercise page with a chart on it' do
  include Rack::Test::Methods
  include PageAssets

  before do
    sign_in_with_a_lift
    log_set 135
    get "/exercises/#{@exercise_id}"
  end

  # A dependency loaded after the thing that depends on it is a dependency that was not
  # there when it was wanted, so the order is asserted and not merely the presence.
  it 'loads Chart.js, then Chartkick' do
    body = last_response.body
    positions = PageAssets::CHART_SCRIPTS.map { |script| body.index(script) }

    assert_equal PageAssets::CHART_SCRIPTS.length, positions.compact.length
    assert_equal positions.compact.sort, positions
  end

  it 'still hands the chart its points' do
    assert_includes last_response.body, 'new Chartkick["LineChart"]'
  end

  # The axis is categories, not a calendar, so there is no date for the adapter to read
  # and 215KB of it stays on the shelf.
  it 'carries no date adapter' do
    refute_includes last_response.body, PageAssets::DATE_ADAPTER
  end
end

# A full, unpurged Tailwind v2 build used to be served beside the app's own styles: 3.82 MB
# uncompressed, on every page load, styling nothing. The v3 CDN does the layout, and the
# v2 file was not even a fallback for it -- utilities the views rely on do not exist in v2.
describe 'the stylesheets a page loads' do
  include Rack::Test::Methods
  include PageAssets

  before { get '/welcome' }

  it 'serves the app stylesheet and no Tailwind build' do
    assert_includes last_response.body, 'styles.css'
    refute_includes last_response.body, 'tailwind.css'
  end

  it 'no longer has a Tailwind build to serve' do
    get '/assets/css/tailwind.css'

    assert_equal 404, last_response.status
  end

  # This asserted the Play CDN was still there, so that removing the vendored v2 build
  # could not be mistaken for removing the thing doing the layout. #142 removed the CDN
  # too -- the stylesheet is compiled and served from this origin now -- so the assertion
  # inverts: what has to be true is that the page has styles and gets them from us.
  it 'loads its styles from this origin rather than from a CDN' do
    get '/welcome'

    refute_includes last_response.body, 'cdn.tailwindcss.com'
    assert_match(%r{<link[^>]*rel="stylesheet"[^>]*href="/assets/css/styles\.css}, last_response.body)
  end
end

