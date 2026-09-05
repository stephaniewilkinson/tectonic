# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #345: the same address could create two accounts, and the second could never be logged
# into. Login always resolved to the first row, so the person who signed up twice got "wrong
# password" on an account they had just made -- and with no reset flow in this app, no way
# out of it. The training logged against the second account was still there and unreachable.
module Uniqueness
  def sign_up(email, password: 'pw12345678')
    get '/create-account'
    post '/create-account', { login: email, password:, '_csrf' => token_from(last_response.body) }
  end

  def alert_text
    last_response.body[/role="alert"[^>]*>\s*([^<]+)/, 1].to_s.strip
  end

  def accounts_for(email) = DB[:accounts].where(email:).count
end

describe 'signing up twice with one address' do
  include Rack::Test::Methods
  include RouteOwnership
  include Uniqueness

  before { @email = "#{SecureRandom.hex}@example.com" }

  it 'creates one account, not two' do
    sign_up(@email)

    assert_equal 1, accounts_for(@email)

    sign_up(@email)

    assert_equal 1, accounts_for(@email)
  end

  it 'refuses the second rather than accepting it' do
    sign_up(@email)
    sign_up(@email)

    assert_equal 422, last_response.status
  end

  # The refusal has to be visible. Nothing in this app rendered a Rodauth error before, so a
  # refused post came back as the same form with nothing on it -- which reads as the button
  # not working, and would have left #345's victim stuck in the same place for a new reason.
  it 'says why, on the page that refused it' do
    sign_up(@email)
    sign_up(@email)

    assert_includes alert_text, 'already exists'
  end

  # Naming the way out, not just the problem. The address they typed is the address they
  # want, so the answer is almost always to log in with it.
  it 'points at logging in' do
    sign_up(@email)
    sign_up(@email)

    assert_includes alert_text, 'Log in instead'
  end
end

describe 'the account that already existed' do
  include Rack::Test::Methods
  include RouteOwnership
  include Uniqueness

  before { @email = "#{SecureRandom.hex}@example.com" }

  # The whole point of the index: the first account stays reachable, and is the only one.
  it 'leaves the original account working' do
    sign_up(@email)
    sign_up(@email)
    get '/logout'
    get '/login'
    post '/login', { login: @email, password: 'pw12345678', '_csrf' => token_from(last_response.body) }

    assert_equal 302, last_response.status
  end
end

describe 'the database rule behind it' do
  include Rack::Test::Methods
  include RouteOwnership

  # The index is what makes the guarantee, rather than a check in the sign-up path that a
  # second writer could race past. Asserted against the constraint directly, because every
  # other route into this table -- a rake task, a console, a future admin page -- gets the
  # rule from here rather than from Rodauth.
  it 'refuses a duplicate address written directly' do
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: 'x', created_on: Time.now)

    assert_raises(Sequel::UniqueConstraintViolation) do
      DB[:accounts].insert(email:, password_hash: 'x', created_on: Time.now)
    end
  end

  # Case is deliberately still free, and this pins that so the gap is a decision on record
  # rather than something discovered later. Closing it means normalising on write *and* on
  # the login lookup; doing only the first would lock out every existing account whose
  # stored address has a capital in it. See the note on migrate/027.
  it 'still allows two accounts differing only in case, which is a known gap' do
    handle = SecureRandom.hex
    DB[:accounts].insert(email: "#{handle}@example.com", password_hash: 'x', created_on: Time.now)
    DB[:accounts].insert(email: "#{handle.upcase}@example.com", password_hash: 'x', created_on: Time.now)

    assert_equal 2, DB[:accounts].where(Sequel.ilike(:email, "#{handle}@example.com")).count
  end
end

# The error surface #345 needed exists on the sign-in form too, since both post to Rodauth
# and both came back silent on a refusal.
describe 'a failed sign-in' do
  include Rack::Test::Methods
  include RouteOwnership
  include Uniqueness

  it 'says something rather than re-rendering an empty form' do
    email, = make_account
    get '/login'
    post '/login', { login: email, password: 'not-the-password', '_csrf' => token_from(last_response.body) }

    refute_empty alert_text
  end
end

