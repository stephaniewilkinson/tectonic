# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The exercise page hands its chart to Chartkick in an inline script, so Rack::Test can
# read the plotted points straight out of the rendered body and no browser is needed.
# What is worth asserting is that the page renders with a line on it and that the points
# are one per recorded day at that day's heaviest weight; what Chart.js paints from them
# is the library's business.
module ExerciseChart
  def app
    Tectonic.app
  end

  def make_account
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    [email, password]
  end

  # A signed-in account with a lift of its own to log sets against.
  def sign_in_with_a_lift
    email, password = make_account
    get '/login'
    post '/login', { login: email, password:, '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    @account_id = DB[:accounts].where(email:).get(:id)
    @exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id: @account_id)
  end

  # One set on a given day, in that day's workout, which is created on first use. The
  # date carries a time of day, as a workout logged through the app does, so the
  # grouping is exercised against the timestamps it will really meet.
  def log_set(weight, on:, is_warmup: false)
    workout_id = DB[:workouts].where(account_id: @account_id, date: on).get(:id) ||
                 DB[:workouts].insert(account_id: @account_id, date: on)
    DB[:sets].insert(workout_id:, exercise_id: @exercise_id, weight:, reps: 5,
                     is_warmup:, is_completed: true)
  end
end

describe 'the exercise page' do
  include Rack::Test::Methods
  include ExerciseChart

  # Two days, each with more than one set, and on the second a warmup heavier than the
  # work: one point per day, at the heaviest weight worked, warmups left out.
  it 'plots the heaviest weight recorded on each day' do
    sign_in_with_a_lift
    log_set 135, on: Time.new(2026, 3, 2, 7, 30)
    log_set 185, on: Time.new(2026, 3, 2, 7, 45)
    log_set 155, on: Time.new(2026, 3, 9, 18, 15)
    log_set 225, on: Time.new(2026, 3, 9, 18, 20), is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Heaviest weight each day'
    assert_includes last_response.body, 'new Chartkick["LineChart"]'
    assert_includes last_response.body, '[["2026-03-02",185],["2026-03-09",155]]'
  end
end

describe 'an exercise with nothing but warmups logged' do
  include Rack::Test::Methods
  include ExerciseChart

  # The page still lists the sets; it is the chart that has nothing to draw, and a lone
  # axis reads worse than no chart at all.
  it 'draws no chart' do
    sign_in_with_a_lift
    log_set 45, on: Time.new(2026, 3, 2, 7, 30), is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '45'
    refute_includes last_response.body, 'Heaviest weight each day'
  end
end

describe 'an exercise with nothing logged at all' do
  include Rack::Test::Methods
  include ExerciseChart

  it 'says so and draws no chart' do
    sign_in_with_a_lift

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'No sets logged yet.'
    refute_includes last_response.body, 'Heaviest weight each day'
  end
end

