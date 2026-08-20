# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The exercise page hands its histogram to Chartkick in an inline script, so Rack::Test
# can read the counts straight out of the rendered body and no browser is needed. What
# is worth asserting is that the page renders with a chart on it and that the numbers
# reaching the chart are the sets this account logged; what Chart.js paints from them is
# the library's business.
module ExerciseHistogram
  def app
    Tectonic.app
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

describe 'the exercise page' do
  include Rack::Test::Methods
  include ExerciseHistogram

  it 'draws a column chart of the weights this account has lifted' do
    sign_in_with_a_lift
    log_set 135
    log_set 185
    log_set 185

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Working sets at each weight'
    assert_includes last_response.body, 'new Chartkick["ColumnChart"]'
    assert_includes last_response.body, '[["135",1],["185",2]]'
  end
end

describe 'an exercise with nothing but warmups logged' do
  include Rack::Test::Methods
  include ExerciseHistogram

  # The page still lists the sets; it is the chart that has nothing to draw, and an
  # axis with no columns under it is worse than no chart at all.
  it 'draws no chart' do
    sign_in_with_a_lift
    log_set 45, is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '45'
    refute_includes last_response.body, 'Working sets at each weight'
  end
end

