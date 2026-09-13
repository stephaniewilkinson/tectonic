# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'

# Where an account is, asked of the browser rather than of the lifter. #349.
#
# `Intl.DateTimeFormat().resolvedOptions().timeZone` returns an IANA name, which is exactly
# what accounts.time_zone stores -- nothing to map, no list to keep in step. The browser has
# known this the whole time and the app never asked.
#
# A settings page that opens on a dropdown of forty zones is a worse first impression than one
# that is already right, and an account that never visits settings is on UTC forever.
module DetectedZone
  # The token comes out of the detector script rather than out of a form, because there is no
  # form: the browser posts this with fetch and nothing on the page changes. route_csrf scopes
  # a token to the path it was minted for, so this is the only place one valid here exists.
  def detected_token
    get '/settings'
    last_response.body[/_csrf', '([^']+)'/, 1]
  end

  def detect(zone, token: nil)
    post '/settings/zone/detected', { 'time_zone' => zone, '_csrf' => token || detected_token }
  end

  def zone_of(account_id) = DB[:accounts].where(id: account_id).get(:time_zone)

  # A real sign-in, because it is the sign-in that decides whether to ask -- `login` from
  # RouteOwnership would work for the endpoint specs and not for these, which are about the
  # flag that hook sets. `zone` is set before signing in for the same reason.
  def sign_in_fresh(zone: nil)
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password),
                         created_on: Time.now, time_zone: zone)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
    DB[:accounts].where(email:).get(:id)
  end
end

describe 'the browser answering where an account is' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  before { @account_id = login }

  it 'stores what the browser said' do
    detect('America/New_York')

    assert_equal 'America/New_York', zone_of(@account_id)
  end

  # Nothing on the page changes, and a redirect would be a navigation nobody asked for in the
  # middle of reading a session.
  it 'answers with no content rather than a redirect' do
    detect('America/New_York')

    assert_equal 204, last_response.status
  end

  # It arrives from a browser, so it is input. A name nothing can resolve would be stored and
  # then read as UTC by every caller, which is the failure the whole of #349 exists to end.
  it 'refuses a name it cannot resolve rather than storing it' do
    detect('Mars/Olympus_Mons')

    assert_nil zone_of(@account_id)
  end

  it 'refuses an offset, which is what a naive detector would send' do
    detect('GMT+5')

    assert_nil zone_of(@account_id)
  end
end

# It is a write from a browser, so it is behind the same guard as every other write here.
describe 'the token the detector posts' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  before { @account_id = login }

  it 'is needed, like every other write in this app' do
    post '/settings/zone/detected', { 'time_zone' => 'America/New_York' }

    assert_nil zone_of(@account_id)
  end

  # route_csrf scopes a token to the path it was minted for, so one lifted from another form
  # on the same page is no use here.
  it 'is no good if it was minted for a different route' do
    detect('America/New_York', token: token_for_form('/settings', '/settings/week'))

    assert_nil zone_of(@account_id)
  end
end

# The rule that makes this safe to run on every sign-in: it fills a blank, it never overrules
# an answer. Somebody who set their home zone deliberately and is signing in from an airport
# keeps the one they chose rather than becoming a resident of the airport.
describe 'an account that has already said where it is' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  it 'keeps the zone it was given, whatever the browser says' do
    account_id = login
    DB[:accounts].where(id: account_id).update(time_zone: 'Europe/London')
    detect('America/New_York')

    assert_equal 'Europe/London', zone_of(account_id)
  end

  # Conditional in the query rather than read-then-write, so two tabs racing cannot have the
  # second overwrite what the first just set.
  it 'is answered the same way, so the browser has nothing to retry' do
    account_id = login
    DB[:accounts].where(id: account_id).update(time_zone: 'Europe/London')
    detect('America/New_York')

    assert_equal 204, last_response.status
  end
end

# Asked once. A detector that reposts on every page for the rest of the session is worse than
# not detecting, and a browser that could not answer will not answer better on the next page.
describe 'when the detector is on the page at all' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  it 'is there after signing in with no zone set' do
    sign_in_fresh
    get '/settings'

    assert_includes last_response.body, 'resolvedOptions'
  end

  it 'is gone once the browser has answered' do
    sign_in_fresh
    detect('America/New_York')
    get '/settings'

    refute_includes last_response.body, 'resolvedOptions'
  end

  # Cleared even on a name that was refused, for the same reason: the next page load will not
  # produce a better answer from the same browser.
  it 'is gone even when the answer was refused' do
    sign_in_fresh
    detect('Mars/Olympus_Mons')
    get '/settings'

    refute_includes last_response.body, 'resolvedOptions'
  end
end

# Every way of answering the question puts the detector away, not only the detector's own.
describe 'the detector once the question is answered another way' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  # Setting one by hand is answering the question, so the detector has nothing left to ask.
  it 'is gone once a zone has been chosen on the settings form' do
    sign_in_fresh
    post '/settings/zone',
         { 'time_zone' => 'Europe/London', '_csrf' => token_for_form('/settings', '/settings/zone') }
    get '/settings'

    refute_includes last_response.body, 'resolvedOptions'
  end
end

# An account that already has one is never asked, so most sessions carry none of this at all --
# no script, no fetch, no endpoint hit.
describe 'the detector for an account that already knows where it is' do
  include Rack::Test::Methods
  include RouteOwnership
  include DetectedZone

  it 'is never on the page' do
    sign_in_fresh(zone: 'Europe/London')
    get '/settings'

    refute_includes last_response.body, '/settings/zone/detected'
  end
end

# What the browser actually answers with, which is the premise the whole approach rests on: an
# IANA name, which is exactly what the column stores. If this were an offset or an
# abbreviation there would be a mapping to write and keep in step, and there is neither.
describe 'what a real browser knows about itself' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include Capybara::DSL

  # Asserted by resolving it rather than by matching a shape. The first version of this
  # required a Region/City pair and failed on CI, whose browser answers "UTC" -- which is a
  # perfectly good IANA identifier with no slash in it, and one this app offers in its own
  # list. The shape was my assumption; being resolvable is the actual requirement.
  it 'answers with a name this app can resolve' do
    visit '/welcome'
    answered = page.evaluate_script('Intl.DateTimeFormat().resolvedOptions().timeZone')

    refute_nil answered
    assert Tectonic::Clock.zone?(answered), "the app refuses what the browser says: #{answered}"
  end
end

# The half no rack_test assertion can reach: a real browser reading its own zone and posting
# it. Everything above asserts the endpoint and the flag; none of it proves the script runs,
# that `Intl` answers, or that the name it answers with is one the app accepts.
#
# It is also the only thing that would have caught where this first went wrong. Creating an
# account does not go through rodauth's `login`, so `after_login` never fires for it and
# anything `after_create_account` puts in the session is wiped by the fixation-clearing inside
# `autologin_session` a few lines later. The detector was simply absent from the page, with
# nothing anywhere saying why.
describe 'a real browser saying where it is' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include Capybara::DSL

  def stored_for(email) = DB[:accounts].where(email:).get(:time_zone)

  it 'sets the zone on a brand new account, without anybody being asked' do
    email = "#{SecureRandom.hex}@example.com"
    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: email
    fill_in 'password', with: SecureRandom.hex
    click_on 'Sign up'

    assert_equal(page.evaluate_script('Intl.DateTimeFormat().resolvedOptions().timeZone'),
                 eventually { stored_for(email) })
  end

  # The fetch is not awaited by the page, so the assertion has to wait for it rather than the
  # navigation -- a fixed sleep would be either flaky or slow.
  def eventually(tries: 40)
    tries.times do
      found = yield
      return found if found

      sleep 0.1
    end
    nil
  end
end

# The other way in. Signing in goes through rodauth's `login` and creating an account does
# not, so the two paths set the flag in different places and both are worth driving.
describe 'a real browser signing in for the first time' do
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include Capybara::DSL

  it 'sets the zone on an account that has never answered' do
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    visit '/login'
    fill_in 'login', with: email
    fill_in 'password', with: password
    click_on 'Sign in'
    stored = nil
    40.times do
      break if (stored = DB[:accounts].where(email:).get(:time_zone))

      sleep 0.1
    end

    refute_nil stored
  end
end

