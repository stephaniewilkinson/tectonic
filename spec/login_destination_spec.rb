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

  # A session with everything in it lifted and nothing said about whether it is over, which
  # is what a session looks like between sets -- and what one looks like three hours later
  # to anybody counting ticked boxes. That is the distinction #523 turns on, so the two
  # helpers are named for it.
  def lifted(workout, at: Time.now)
    exercise_id = Tectonic::Exercise.insert(account_id: workout.account_id, name: "L#{SecureRandom.hex(4)}")
    Tectonic::WorkoutSet.insert(workout_id: workout.id, exercise_id:, weight: 225, reps: 5,
                                is_warmup: false, is_completed: true, completed_at: at)
    workout
  end

  # And the lifter saying they are done, which is the only thing `finished_at` means: the
  # control at the top of the session screen, the nudge, or SessionClose.sweep stamping it
  # on their behalf hours after they left. Stamped at the last set the way the latter two do.
  def finished(workout, at: Time.now)
    lifted(workout, at:)
    workout.update(finished_at: at)
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

  # The brand new account, which since #575 arrives here one flow later than it used to.
  # Signing up no longer opens a session, so the redirect that chooses a destination moved
  # from `create_account_redirect` to `verify_account_redirect` -- and the first request a new
  # account makes with a session in it is now the confirmation, not the sign-up. This is the
  # only case the first-run page was ever written for, so it is asserted from where it now
  # happens rather than dropped.
  it 'lands there when the account was confirmed a moment ago, not on an empty calendar' do
    email = "#{SecureRandom.hex}@example.com"
    get '/create-account'
    post '/create-account', { login: email, '_csrf' => token_from(last_response.body) }
    row = DB[:account_verification_keys].where(id: DB[:accounts].where(email:).get(:id)).first
    get "/verify-account?key=#{row[:id]}_#{row[:key]}"
    follow_redirect! while last_response.redirect?
    # The password is typed here, on the page the link leads to, and not on the sign-up form.
    post '/verify-account', { password: 'pw12345678', '_csrf' => token_from(last_response.body) }

    assert_equal '/start', last_response.headers['location']
  end

  # And the half of that which used to be implied: the sign-up itself goes nowhere that needs
  # a session. The old redirect ran `login_destination`, which ends at a page behind
  # `require_login`, so leaving it in place would have sent every new account straight into
  # the login screen with the "check your email" notice consumed on the way past.
  it 'sends a sign-up to the login page rather than anywhere that needs a session' do
    get '/create-account'
    post '/create-account', { login: "#{SecureRandom.hex}@example.com",
                              '_csrf' => token_from(last_response.body) }

    assert_equal '/login', last_response.headers['location']
  end
end

describe 'signing in with training behind you but none written for today' do
  include Rack::Test::Methods
  include LandingAfterLogin

  # The calendar since #635, where it was the new-workout form: on a day with nothing
  # written, the useful answer is the week, and logging something unplanned is a tap from it.
  it 'lands on the calendar' do
    email, password, = account_with(Date.today - 3, Date.today - 10)
    assert_equal '/', land(email, password)
  end

  # A session dated ahead is a plan, not something to open today -- but it is exactly what the
  # calendar shows, which is the case #635 was about: an assistant wrote the block, the first
  # session is Monday, and a blank form on Saturday said nothing about it.
  it 'lands there when the only other session is still in the future' do
    email, password, = account_with(Date.today + 2)
    assert_equal '/', land(email, password)
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

  it 'picks the one written first when two are still to do' do
    email, password, workouts = account_with(Time.now, Time.now)
    assert_equal "/workouts/#{workouts.map(&:id).min}/session", land(email, password)
  end

  # Every set ticked is not the same statement as "I am done", and only the second one is
  # worth acting on: three of ten done is "I stopped early" and "I am between sets" written
  # identically, so a session nobody has closed is a session still under way. A set can be
  # added, corrected or rated here, and all three happen on this screen.
  it 'lands there even when every set in it is already lifted' do
    email, password, workouts = account_with(Time.now)
    lifted(workouts.first)
    assert_equal "/workouts/#{workouts.first.id}/session", land(email, password)
  end
end

# #523: the app told a lifter they were still training every time they signed in, because
# any session dated today sent them to the gym floor whether or not it was over.
describe 'signing in after the day is trained' do
  include Rack::Test::Methods
  include LandingAfterLogin

  # The record, which is where somebody asking about a day they have already trained is
  # going. It is one tap from the session screen, so a set added or corrected afterwards
  # costs a tap rather than being shut out.
  it 'lands on the record of a session finished earlier today' do
    email, password, workouts = account_with(Time.now)
    finished(workouts.first, at: Time.now - (11 * 60 * 60))
    assert_equal "/workouts/#{workouts.first.id}", land(email, password)
  end

  # The sweep runs on this very path, immediately above the lookup, so a session abandoned
  # this morning is closed by the time the destination is chosen -- and the lifter who never
  # tapped finish lands where the one who did lands.
  it 'lands on the record of a session the sweep closed on the way in' do
    email, password, workouts = account_with(Time.now)
    lifted(workouts.first, at: Time.now - (8 * 60 * 60))
    assert_equal "/workouts/#{workouts.first.id}", land(email, password)
  end

  # A session finished yesterday is not today's session at all, and a day with training
  # written for it and nothing done is still a day to lift.
  it 'lands on the gym floor for today when yesterday was finished' do
    email, password, workouts = account_with(Date.today - 1, Time.now)
    finished(workouts.first, at: Time.now - (24 * 60 * 60))
    assert_equal "/workouts/#{workouts.last.id}/session", land(email, password)
  end
end

# Nothing forbids two sessions on one day, and the old rule took the lowest id, which is
# arbitrary the moment there is a second one. A lifter who has trained this morning and has
# an evening session written is coming back for the evening session.
describe 'signing in on a day with two sessions written for it' do
  include Rack::Test::Methods
  include LandingAfterLogin

  it 'lands on the evening session when the morning one is finished' do
    email, password, workouts = account_with(Time.now, Time.now)
    finished(workouts.first, at: Time.now - (11 * 60 * 60))
    assert_equal "/workouts/#{workouts.last.id}/session", land(email, password)
  end

  # And the same day from the other end: both done, so the record shown is the session they
  # have just come out of. Written twice with the finishes the other way round, because one
  # of them on its own is passed by "lowest id wins" and the other by "highest id wins", and
  # the rule is neither: the stamp decides, and the ids are there to be ignored.
  it 'lands on the record of the last one finished when both are done' do
    email, password, workouts = account_with(Time.now, Time.now)
    finished(workouts.first, at: Time.now - (30 * 60))
    finished(workouts.last, at: Time.now - (9 * 60 * 60))
    assert_equal "/workouts/#{workouts.first.id}", land(email, password)
  end

  it 'lands on the record of the last one finished when the later-written one is the later one' do
    email, password, workouts = account_with(Time.now, Time.now)
    finished(workouts.first, at: Time.now - (9 * 60 * 60))
    finished(workouts.last, at: Time.now - (30 * 60))
    assert_equal "/workouts/#{workouts.last.id}", land(email, password)
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

  # Two since #629: connecting an assistant, and logging a session. The block card linked to
  # /programs, which #411 had already turned into a redirect to an empty list.
  it 'offers the two ways in it describes' do
    email, password, = account_with
    land(email, password)
    get '/start'

    %w[/connections /workouts/new].each do |path|
      assert_includes last_response.body, %(href="#{path}")
    end
  end
end

