# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/clock'
require 'securerandom'

# What day it is for the lifter, rather than for the server. #349.
#
# Every "today" in this app was `Date.today`, which is the server's, and the server is UTC. A
# lifter in New York at 8:30pm Monday was acting on Tuesday: signing in missed the session they
# came back to finish, asking an assistant to log "today" opened a second empty workout beside
# the real one, and the Monday session they were halfway through read as skipped.
#
# **The suite could not see any of it**, and that is the part worth saying out loud: both sides
# of every assertion used the same clock, so the bug was invisible to exactly the thing that
# should have caught it. Every spec here pins a `now` and a zone that disagree about the date,
# which is the only way to write a test that could have failed before the fix.
module LiftersDay
  # Half past eight on a Monday evening in New York, which is already Tuesday in UTC. The
  # instant #349 is about, and the one the whole app used to get wrong.
  MONDAY_EVENING = Time.utc(2026, 9, 15, 0, 30) # 2026-09-14 20:30 -0400
  NEW_YORK = 'America/New_York'

  def zone_of(account_id, zone)
    DB[:accounts].where(id: account_id).update(time_zone: zone)
  end
end

describe 'the day an account is on' do
  include LiftersDay

  it 'is the server day where no zone is set, which is what every account had before' do
    assert_equal Date.new(2026, 9, 15), Tectonic::Clock.today(nil, now: LiftersDay::MONDAY_EVENING)
  end

  it 'is still Monday in New York when UTC has gone over to Tuesday' do
    assert_equal Date.new(2026, 9, 14), Tectonic::Clock.today(LiftersDay::NEW_YORK, now: LiftersDay::MONDAY_EVENING)
  end

  it 'is already Tuesday in Sydney' do
    assert_equal Date.new(2026, 9, 15), Tectonic::Clock.today('Australia/Sydney', now: LiftersDay::MONDAY_EVENING)
  end

  # An IANA name rather than an offset, so the clocks going back is not a thing anybody has to
  # remember. The same zone answers differently in January and July and neither is edited.
  it 'follows the clocks without being told' do
    winter = Time.utc(2026, 1, 15, 2, 30)
    summer = Time.utc(2026, 7, 15, 2, 30)

    assert_equal Date.new(2026, 1, 14), Tectonic::Clock.today(LiftersDay::NEW_YORK, now: winter)
    assert_equal Date.new(2026, 7, 14), Tectonic::Clock.today(LiftersDay::NEW_YORK, now: summer)
  end
end

# A zone nothing can resolve is a reason to be hours wrong about a calendar, not a reason to
# refuse to serve somebody's session. Writing one is refused up front instead.
describe 'a zone the app cannot resolve' do
  it 'falls back to UTC rather than raising' do
    assert_equal Date.new(2026, 9, 15),
                 Tectonic::Clock.today('Mars/Olympus_Mons', now: LiftersDay::MONDAY_EVENING)
  end

  it 'is refused before it can be stored' do
    refute Tectonic::Clock.zone?('EST5EDT_nonsense')
    refute Tectonic::Clock.zone?('GMT+5')
    assert Tectonic::Clock.zone?('America/New_York')
  end

  # Blank is a real answer meaning UTC, not a malformed one.
  it 'treats blank as unset rather than as a bad name' do
    refute Tectonic::Clock.zone?('')
    assert_nil Tectonic::Clock.resolve(nil)
  end
end

# The first of the three failures #349 names, and the one it leads with.
describe 'signing in on a Monday evening in New York' do
  include Rack::Test::Methods
  include RouteOwnership
  include LiftersDay

  # Asked of login_destination directly, which is what Rodauth's login_redirect calls. Driving
  # a sign-in through the form would work too and would assert the same thing twice over --
  # this is the method the whole failure lives in.
  it 'lands on the session that Monday rather than on the new-workout stub' do
    account_id = login
    zone_of(account_id, LiftersDay::NEW_YORK)
    monday = DB[:workouts].insert(account_id:, date: Date.new(2026, 9, 14))

    on_monday_evening do
      assert_equal "/workouts/#{monday}/session", Tectonic.new({}).login_destination(account_id)
    end
  end

  # The same account without a zone gets the old answer, which is the behaviour every account
  # keeps until somebody sets one.
  it 'still reads the server day where no zone is set' do
    account_id = login
    monday = DB[:workouts].insert(account_id:, date: Date.new(2026, 9, 14))

    on_monday_evening do
      refute_equal "/workouts/#{monday}/session", Tectonic.new({}).login_destination(account_id)
    end
  end

  # Pinning the clock is the only way any of this is testable: with the real one, both sides
  # of the assertion agree and the bug is invisible.
  def on_monday_evening(&)
    Time.stub(:now, LiftersDay::MONDAY_EVENING, &)
  end
end

# The second failure: asked to log "today", an assistant on the server's clock opened a second
# empty workout beside the real one -- the exact duplicate create_workout promises not to make.
describe 'an assistant logging today on a Monday evening in New York' do
  include Rack::Test::Methods
  include LiftersDay

  it 'finds the session already open rather than starting a second one' do
    token = mint(scopes: %w[read write])
    zone_of(token.account_id, LiftersDay::NEW_YORK)
    monday = DB[:workouts].insert(account_id: token.account_id, date: Date.new(2026, 9, 14))

    Time.stub(:now, LiftersDay::MONDAY_EVENING) do
      call_tool('create_workout', raw: token.raw, arguments: {})
    end

    assert_equal 1, DB[:workouts].where(account_id: token.account_id).count
    assert_equal monday, DB[:workouts].where(account_id: token.account_id).get(:id)
  end
end

# The third: a session in progress read as skipped while it was being lifted.
describe 'a Monday evening session in progress' do
  include LiftersDay

  it 'reads as planned rather than skipped for a lifter still in it' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    workout = Tectonic::Workout.create(account_id:, date: Date.new(2026, 9, 14))

    assert_equal :planned, workout.status(Tectonic::Clock.today(LiftersDay::NEW_YORK, now: LiftersDay::MONDAY_EVENING))
    assert_equal :skipped, workout.status(Tectonic::Clock.today(nil, now: LiftersDay::MONDAY_EVENING))
  end
end

describe 'choosing a zone on the settings page' do
  include Rack::Test::Methods
  include RouteOwnership

  def save(zone)
    post '/settings/zone',
         { 'time_zone' => zone, '_csrf' => token_for_form('/settings', '/settings/zone') }
  end

  it 'stores one the app can resolve' do
    account_id = login
    save('America/New_York')

    assert_equal 'America/New_York', DB[:accounts].where(id: account_id).get(:time_zone)
  end

  # Refused rather than written and ignored. A stored name nothing resolves reads as UTC to
  # every caller, which is the failure this whole change exists to end.
  it 'refuses one it cannot, rather than storing it' do
    account_id = login
    save('America/New_York')
    save('GMT+5')

    assert_equal 'America/New_York', DB[:accounts].where(id: account_id).get(:time_zone)
  end

  it 'takes blank as unset' do
    account_id = login
    save('America/New_York')
    save('')

    assert_nil DB[:accounts].where(id: account_id).get(:time_zone)
  end
end

describe 'the settings page itself' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'offers the picker, and says what today is so the setting can be checked at a glance' do
    login
    get '/settings'

    assert_includes last_response.body, 'name="time_zone"'
    assert_includes last_response.body, 'America/New_York'
    assert_includes last_response.body, 'Today here is'
  end
end

# A zone set by hand, or by anything other than this form, must survive the form being saved.
# Without it the select would hold no matching option and the browser would submit the first.
describe 'a stored zone that is not one of the offerings' do
  it 'is kept in the list so saving the form cannot move it' do
    options = Tectonic::Clock.zone_options('America/Argentina/Ushuaia')

    assert_equal 'America/Argentina/Ushuaia', options.first
    assert_includes options, 'Europe/London'
  end

  it 'does not duplicate one that is already offered' do
    assert_equal Tectonic::Clock::OFFERED, Tectonic::Clock.zone_options('Europe/London')
  end
end

