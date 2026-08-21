# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The assistants page, driven as a logged-in browser drives it. Two accounts exist
# throughout: the one signed in, and a stranger whose connections must stay invisible
# and unrevokable.
module Connecting
  def app
    Tectonic.app
  end

  def sign_up
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'))
    get '/login'
    post '/login', { login: email, password: 'pw12345678', '_csrf' => token_from(last_response.body) }
    DB[:accounts].where(email:).get(:id)
  end

  # An assistant that has been authorized: a registered client plus a live grant.
  def connect(account_id, name: 'Claude', scopes: 'read write', created_at: Time.now, revoked_at: nil)
    application = DB[:oauth_applications].insert(
      name:, client_id: SecureRandom.uuid, client_secret: SecureRandom.hex,
      redirect_uri: 'https://claude.ai/api/mcp/auth_callback', scopes: 'read write'
    )
    DB[:oauth_grants].insert(account_id:, oauth_application_id: application, scopes:, created_at:,
                             revoked_at:, expires_in: Time.now + 3600)
    application
  end

  def token_from(body)
    body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
  end

  # The token the disconnect form for this assistant carries.
  def disconnect_token(application_id)
    get '/connections'
    last_response.body[%r{action="/connections/#{application_id}".*?value="([^"]*)"}m, 1]
  end

  # The public origin is read from the environment at request time, so a test can put a
  # real one in place for the duration of one request.
  def with_base_url(value)
    before = ENV.fetch('MCP_PUBLIC_BASE_URL', nil)
    value.nil? ? ENV.delete('MCP_PUBLIC_BASE_URL') : ENV['MCP_PUBLIC_BASE_URL'] = value
    yield
  ensure
    before.nil? ? ENV.delete('MCP_PUBLIC_BASE_URL') : ENV['MCP_PUBLIC_BASE_URL'] = before
  end

  def live_grants(account_id, application_id)
    DB[:oauth_grants].where(account_id:, oauth_application_id: application_id, revoked_at: nil).count
  end
end

describe 'the assistants page' do
  include Rack::Test::Methods
  include Connecting

  it 'requires a login' do
    get '/connections'
    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], '/login'
  end

  # Asserted against a real origin rather than against Config.resource_url, which would
  # be the same expression the route uses and so would pass even when it produced the
  # bare path "/mcp" that an unset MCP_PUBLIC_BASE_URL yields.
  it 'shows the full address to paste into an assistant' do
    sign_up
    with_base_url('https://tectonicplates.app') { get '/connections' }

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'https://tectonicplates.app/mcp'
  end

  # Half an address is worse than none: a lifter copies it, their assistant fails, and
  # nothing says the deployment was never told its own origin.
  it 'says so rather than showing half an address when the origin is unset' do
    sign_up
    with_base_url(nil) { get '/connections' }

    refute_includes last_response.body, 'id="mcp-url"'
    assert_includes last_response.body, 'MCP_PUBLIC_BASE_URL'
  end
end

describe 'the assistants page once something is connected' do
  include Rack::Test::Methods
  include Connecting

  it 'says nothing is connected when nothing is' do
    sign_up
    get '/connections'
    assert_includes last_response.body, 'Nothing is connected yet'
  end

  it 'lists a connected assistant with its scopes' do
    account = sign_up
    connect(account, name: 'Claude', scopes: 'read write')
    get '/connections'

    assert_includes last_response.body, 'Claude'
    assert_includes last_response.body, 'read, write'
  end
end

describe 'what the assistants page does not show' do
  include Rack::Test::Methods
  include Connecting

  it "never shows a stranger's connection" do
    stranger = sign_up
    connect(stranger, name: 'StrangersBot')

    sign_up
    get '/connections'

    refute_includes last_response.body, 'StrangersBot'
  end

  # A grant that was revoked is not a connection, and neither is one whose refresh window
  # has closed -- both would otherwise offer a Disconnect button that does nothing.
  it 'leaves out an assistant whose grant was already revoked' do
    account = sign_up
    connect(account, name: 'RevokedBot', revoked_at: Time.now)
    get '/connections'

    refute_includes last_response.body, 'RevokedBot'
  end
end

# One assistant authorized twice is one assistant, not two rows a lifter has to reason
# about, and the scopes it holds are what either authorization granted.
describe 'an assistant authorized more than once' do
  include Rack::Test::Methods
  include Connecting

  it 'folds repeat authorizations of the same assistant into one entry' do
    account = sign_up
    application = DB[:oauth_applications].insert(
      name: 'Claude', client_id: SecureRandom.uuid, client_secret: SecureRandom.hex,
      redirect_uri: 'https://claude.ai/api/mcp/auth_callback', scopes: 'read write'
    )
    2.times do |i|
      DB[:oauth_grants].insert(account_id: account, oauth_application_id: application,
                               scopes: i.zero? ? 'read' : 'write', expires_in: Time.now + 3600)
    end
    get '/connections'

    assert_equal 1, last_response.body.scan(%r{<form method="post" action="/connections/}).length
    assert_includes last_response.body, 'read, write'
  end
end

describe 'disconnecting an assistant' do
  include Rack::Test::Methods
  include Connecting

  it 'revokes every grant it holds, not just one' do
    account = sign_up
    application = connect(account)
    DB[:oauth_grants].insert(account_id: account, oauth_application_id: application,
                             scopes: 'read', expires_in: Time.now + 3600)
    assert_equal 2, live_grants(account, application)

    post "/connections/#{application}", { '_csrf' => disconnect_token(application) }

    assert_equal 0, live_grants(account, application)
  end

  it 'refuses without a CSRF token and revokes nothing' do
    account = sign_up
    application = connect(account)

    post "/connections/#{application}", {}

    assert_equal 403, last_response.status
    assert_equal 1, live_grants(account, application)
  end
end

# The id in the path is the caller's only say in what gets revoked, so it has to be scoped
# to them: a stranger's assistant must survive being named here.
describe 'disconnecting something that is not yours' do
  include Rack::Test::Methods
  include Connecting

  # This case only proves the CSRF token is bound to its path: the post is refused before
  # the revoke runs at all. Worth asserting, but it is not the account check, so the check
  # itself is exercised directly below.
  it "refuses a post aimed at a stranger's assistant" do
    stranger = sign_up
    application = connect(stranger)

    account = sign_up
    mine = connect(account)
    post "/connections/#{application}", { '_csrf' => disconnect_token(mine) }

    assert_equal 403, last_response.status
    assert_equal 1, live_grants(stranger, application)
  end

  # The guard that matters, reached directly, because a logged-in caller can put any id in
  # the path and CSRF says nothing about whose row it names. Dropping the account from the
  # filter has to fail this.
  it 'revokes nothing when the assistant belongs to another account' do
    stranger = sign_up
    application = connect(stranger)
    account = sign_up

    assert_equal 0, Tectonic::Connection.revoke(account, application)
    assert_equal 1, live_grants(stranger, application)
  end
end

