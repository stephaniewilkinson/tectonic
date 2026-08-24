# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account and CSRF helpers; idempotent require
require 'securerandom'
require 'date'

# Where signing in puts you. Every assertion reads the Location of the login POST rather
# than following it, because that one redirect is the whole decision -- nothing later in
# the request revisits it.
module LandingAfterLogin
  include RouteOwnership

  # An account with its training already in place. It has to be in place before the
  # login, which is the moment the destination is chosen.
  def account_with(*dates)
    email, password = make_account
    account_id = DB[:accounts].where(email:).get(:id)
    [email, password, dates.map { |date| Tectonic::Workout.create(account_id:, date:) }]
  end

  def land(email, password)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
    last_response.headers['location']
  end

  # A session with everything in it lifted, which is what a training day looks like by
  # the evening.
  def finish(workout)
    exercise_id = Tectonic::Exercise.insert(account_id: workout.account_id, name: "L#{SecureRandom.hex(4)}")
    Tectonic::Set.insert(workout_id: workout.id, exercise_id:, weight: 225, reps: 5,
                         is_warmup: false, is_completed: true)
    workout
  end
end

describe 'signing in with nothing logged' do
  include Rack::Test::Methods
  include LandingAfterLogin

  it 'lands on the first-run page' do
    email, password, = account_with
    assert_equal '/start', land(email, password)
  end

  it 'lands there when the account was made a moment ago, not on an empty calendar' do
    email = "#{SecureRandom.hex}@example.com"
    get '/create-account'
    post '/create-account', { login: email, 'login-confirm' => email, password: 'pw12345678',
                              'password-confirm' => 'pw12345678', '_csrf' => token_from(last_response.body) }
    assert_equal '/start', last_response.headers['location']
  end
end

describe 'signing in with training behind you but none written for today' do
  include Rack::Test::Methods
  include LandingAfterLogin

  it 'lands on the new-workout form' do
    email, password, = account_with(Date.today - 3, Date.today - 10)
    assert_equal '/workouts/new', land(email, password)
  end

  # A session dated ahead is a plan, not something to open today: nothing is due yet.
  it 'lands there when the only other session is still in the future' do
    email, password, = account_with(Date.today + 2)
    assert_equal '/workouts/new', land(email, password)
  end
end

describe 'signing in on a day that has a session written' do
  include Rack::Test::Methods
  include LandingAfterLogin

  # Time.now rather than a bare Date, so the row holds a real time of day. A session
  # written at midnight would match a naive timestamp equality and hide the cast.
  it 'lands on the gym-floor screen for it' do
    email, password, workouts = account_with(Date.today - 3, Time.now)
    assert_equal "/workouts/#{workouts.last.id}/session", land(email, password)
  end

  it 'picks the one written first when two share the day' do
    email, password, workouts = account_with(Time.now, Time.now)
    assert_equal "/workouts/#{workouts.map(&:id).min}/session", land(email, password)
  end

  # A finished session is still today's session. Every set is lifted, but a set can be
  # added, corrected or rated afterwards, and all three happen on this screen.
  it 'lands there even when every set in it is already lifted' do
    email, password, workouts = account_with(Time.now)
    finish(workouts.first)
    assert_equal "/workouts/#{workouts.first.id}/session", land(email, password)
  end
end

describe 'the first-run page' do
  include Rack::Test::Methods
  include LandingAfterLogin

  it 'is closed to anyone not signed in' do
    get '/start'
    assert_equal 302, last_response.status
    assert_includes last_response.headers['location'], '/login'
  end

  it 'is reachable at its own address by an account that has already trained' do
    email, password, = account_with(Date.today - 3)
    land(email, password)
    get '/start'

    assert last_response.ok?
    assert_includes last_response.body, 'Start here'
  end

  it 'offers the three things it says are worth doing first' do
    email, password, = account_with
    land(email, password)
    get '/start'

    %w[/workouts/new /programs /connections].each do |path|
      assert_includes last_response.body, %(href="#{path}")
    end
  end
end

