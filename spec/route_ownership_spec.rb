# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The workout and set routes, driven as a logged-in browser would drive them. Two
# accounts exist throughout: the one signed in, and a stranger whose rows it must not
# be able to read or write. Rack::Test rather than Capybara because these assert what
# the database holds afterwards, which a browser adds nothing to.
module RouteOwnership
  def app
    Tectonic.app
  end

  def make_account
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    [email, password]
  end

  def login
    email, password = make_account
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
    DB[:accounts].where(email:).get(:id)
  end

  # A workout owned by someone else, with one set in it.
  def strangers_workout
    email, = make_account
    account_id = DB[:accounts].where(email:).get(:id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    set_id = DB[:sets].insert(workout_id:, exercise_id:, weight: 100, reps: 5,
                              is_warmup: false, is_completed: false)
    [workout_id, set_id]
  end

  def own_workout(account_id)
    DB[:workouts].insert(account_id:, date: Time.now)
  end

  def token_from(body)
    body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
  end

  # The CSRF token a form on `path` carries, so a test can post the way the form does.
  def token_for(path)
    get path
    token_from(last_response.body)
  end
end

describe 'workout rescheduling is owner-only' do
  include Rack::Test::Methods
  include RouteOwnership

  it "refuses to move a stranger's workout to a new date" do
    login
    workout_id, = strangers_workout
    before = DB[:workouts].where(id: workout_id).get(:date)

    post '/workouts', { id: workout_id.to_s, date: '2030-01-01', '_csrf' => token_for('/workouts/new') }

    assert_equal before, DB[:workouts].where(id: workout_id).get(:date)
  end

  it 'still reschedules a workout the account owns' do
    account_id = login
    workout_id = own_workout(account_id)

    post '/workouts', { id: workout_id.to_s, date: '2030-01-01', '_csrf' => token_for('/workouts/new') }

    assert_equal Date.new(2030, 1, 1), DB[:workouts].where(id: workout_id).get(:date).to_date
  end
end

describe 'a set is reachable only through the workout that owns it' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    @mine = own_workout(@account_id)
    _, @strangers_set = strangers_workout
  end

  it "refuses to write a stranger's set through a workout the account owns" do
    path = "/workouts/#{@mine}/sets/#{@strangers_set}"
    post path, { weight: '999', reps: '1', '_csrf' => token_for("/workouts/#{@mine}/sets/new") }

    assert_equal 100, DB[:sets].where(id: @strangers_set).get(:weight)
  end

  it "refuses to show a stranger's set" do
    get "/workouts/#{@mine}/sets/#{@strangers_set}"
    assert_equal 302, last_response.status
    refute_includes last_response.body.to_s, '100'
  end

  it "refuses to open the edit form for a stranger's set" do
    get "/workouts/#{@mine}/sets/#{@strangers_set}/edit"
    assert_equal 302, last_response.status
  end
end

describe 'state-changing posts require a CSRF token' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    @workout = own_workout(@account_id)
  end

  it 'refuses a workout post with no token' do
    post '/workouts', { date: '2030-01-01' }
    assert_equal 403, last_response.status
  end

  # The name is unique per run so the assertion cannot be satisfied or defeated by a
  # row some earlier run left behind.
  it 'refuses an exercise post with no token' do
    name = "Forged #{SecureRandom.hex(4)}"
    post '/exercises', { id: '', name:, icon_url: '' }

    assert_equal 403, last_response.status
    assert_equal 0, DB[:exercises].where(name:).count
  end

  it 'refuses a new-set post with no token' do
    post "/workouts/#{@workout}/sets/new", { weight: '135', reps: '5', exercise_id: '1' }
    assert_equal 403, last_response.status
    assert_equal 0, DB[:sets].where(workout_id: @workout).count
  end
end

