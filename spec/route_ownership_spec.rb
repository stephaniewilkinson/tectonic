# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# Seeded here, as five other spec files do, because the last spec in this file logs a set
# against a library movement and this file seeded none. It passed anyway in a full run:
# another file seeds the library at load time and the teardown deliberately keeps the rows
# with no account behind them, so whichever file ran first left one lying there. Run on its
# own -- which is how the README says to run a single file -- there was no library row,
# `get(:id)` came back nil, the post was refused for a movement that did not resolve, and
# the assertion after it failed on a suite that is otherwise green.
Tectonic::Exercise.load_library

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

# A set points at a movement, and the only movements an account may point at are its own
# and the shared library. The id arrives from a form, so it cannot be taken on trust.
describe 'logging a set against a movement you cannot see' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    @workout = own_workout(@account_id)
  end

  # A stranger's private movement, reachable only by guessing its id.
  def strangers_exercise
    email, = make_account
    owner = DB[:accounts].where(email:).get(:id)
    DB[:exercises].insert(name: "Private #{SecureRandom.hex(4)}", account_id: owner)
  end

  it 'refuses the set rather than attaching a stranger\'s private movement' do
    hidden = strangers_exercise
    post "/workouts/#{@workout}/sets/new",
         { weight: '135', reps: '5', exercise_id: hidden.to_s,
           '_csrf' => token_for("/workouts/#{@workout}/sets/new") }

    assert_equal 0, DB[:sets].where(workout_id: @workout).count
  end

  it 'still logs a set against a movement the account can see' do
    library = DB[:exercises].where(account_id: nil).get(:id)
    post "/workouts/#{@workout}/sets/new",
         { weight: '135', reps: '5', exercise_id: library.to_s,
           '_csrf' => token_for("/workouts/#{@workout}/sets/new") }

    assert_equal 1, DB[:sets].where(workout_id: @workout).count
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

