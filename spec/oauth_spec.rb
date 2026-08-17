# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require 'bcrypt'
require 'securerandom'
require 'digest'
require 'base64'
require 'json'

# The public origin (and token audience) the app derives its OAuth surface from, and the
# one non-loopback callback claude.ai uses.
RESOURCE = Tectonic::MCP::Config.resource_url
CALLBACK = 'https://claude.ai/api/mcp/auth_callback'

# Shared OAuth test helpers, included per-describe rather than defined at the top level so
# they never clobber another spec's global helpers (mcp_spec defines its own new_account).
# `app` is the production URLMap: /mcp to the plain-Rack MCP stack, everything else to Roda.
module OAuthTest
  def app
    @app ||= Rack::URLMap.new(
      Tectonic::MCP::Config.endpoint_path => Tectonic::MCP.rack_app, '/' => Tectonic.app
    )
  end

  def make_account
    email = "#{SecureRandom.hex}@example.com"
    id = DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'),
                              created_on: Time.now)
    [id, email, 'pw12345678']
  end

  def register_client(redirect_uris: [CALLBACK])
    Tectonic::OAuthClient.register(client_name: 'Claude', redirect_uris:,
                                   grant_types: %w[authorization_code refresh_token],
                                   response_types: ['code'], scopes: %w[read write offline_access])
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(32)
    [verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)]
  end

  def mint_code(account_id, client, challenge)
    request = Tectonic::OAuth::AuthorizeRequest.new(
      client:, client_id: client.client_id, redirect_uri: CALLBACK, scopes: %w[read],
      code_challenge: challenge, code_challenge_method: 'S256', resource: RESOURCE, state: nil
    )
    Tectonic::OAuthAuthorizationCode.mint(request:, account_id:)
  end

  def code_grant(client, code, verifier)
    { grant_type: 'authorization_code', code:, redirect_uri: CALLBACK,
      client_id: client.client_id, code_verifier: verifier, resource: RESOURCE }
  end

  def token_post(params)
    post 'http://localhost/token', params
  end

  def json_body
    JSON.parse(last_response.body)
  end

  def login(email, password)
    get 'http://localhost/login'
    csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post 'http://localhost/login', { login: email, password:, '_csrf' => csrf }
  end

  def mcp_call(token)
    env = { 'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream' }
    env = env.merge('HTTP_AUTHORIZATION' => "Bearer #{token}") if token
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'whoami', arguments: {} } }
    post 'http://localhost/mcp', body.to_json, env
  end
end

describe 'OAuth protected-resource metadata' do
  include Rack::Test::Methods
  include OAuthTest

  it 'advertises the resource and its authorization server' do
    get 'http://localhost/.well-known/oauth-protected-resource'
    assert_equal 200, last_response.status
    assert_equal RESOURCE, json_body['resource']
    assert_includes json_body['scopes_supported'], 'offline_access'
    assert_equal ['header'], json_body['bearer_methods_supported']
  end
end

describe 'OAuth authorization-server metadata' do
  include Rack::Test::Methods
  include OAuthTest

  it 'advertises S256 PKCE and the supported grants' do
    get 'http://localhost/.well-known/oauth-authorization-server'
    assert_equal ['code'], json_body['response_types_supported']
    assert_equal ['S256'], json_body['code_challenge_methods_supported']
    assert_equal %w[authorization_code refresh_token], json_body['grant_types_supported']
  end
end

describe 'OAuth dynamic client registration' do
  include Rack::Test::Methods
  include OAuthTest

  it 'registers a public client and returns its id' do
    post 'http://localhost/register', { redirect_uris: [CALLBACK] }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 201, last_response.status
    assert_equal 'none', json_body['token_endpoint_auth_method']
    assert Tectonic::OAuthClient.locate(json_body['client_id'])
  end

  it 'rejects a redirect_uri that is neither claude.ai nor loopback' do
    post 'http://localhost/register', { redirect_uris: ['https://evil.example.com/cb'] }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 400, last_response.status
    assert_equal 'invalid_client_metadata', json_body['error']
  end
end

describe 'OAuth authorize login requirement' do
  include Rack::Test::Methods
  include OAuthTest

  it 'redirects an unauthenticated authorize request to login' do
    client = register_client
    _, challenge = pkce
    get 'http://localhost/authorize',
        { response_type: 'code', client_id: client.client_id, redirect_uri: CALLBACK,
          scope: 'read', code_challenge: challenge, code_challenge_method: 'S256', resource: RESOURCE }
    assert_equal 302, last_response.status
    assert_includes last_response.headers['location'], '/login'
  end
end

describe 'OAuth authorize validation' do
  include Rack::Test::Methods
  include OAuthTest

  it 'shows an error page for an unknown client' do
    get 'http://localhost/authorize',
        { response_type: 'code', client_id: 'nope', redirect_uri: CALLBACK,
          code_challenge: 'x', code_challenge_method: 'S256' }
    assert_equal 400, last_response.status
  end

  it 'rejects a plain (non-S256) code challenge by redirecting with an error' do
    client = register_client
    get 'http://localhost/authorize',
        { response_type: 'code', client_id: client.client_id, redirect_uri: CALLBACK,
          code_challenge: 'x', code_challenge_method: 'plain', state: 's' }
    assert_includes last_response.headers['location'], 'error=invalid_request'
  end
end

describe 'OAuth authorize consent' do
  include Rack::Test::Methods
  include OAuthTest

  it 'issues a code after the account approves the consent screen' do
    _, email, password = make_account
    client = register_client
    _, challenge = pkce
    login(email, password)
    query = { response_type: 'code', client_id: client.client_id, redirect_uri: CALLBACK,
              scope: 'read write', state: 'abc', code_challenge: challenge,
              code_challenge_method: 'S256', resource: RESOURCE }
    get 'http://localhost/authorize', query
    csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post 'http://localhost/authorize', query.merge('_csrf' => csrf)
    assert_includes last_response.headers['location'], "#{CALLBACK}?code="
    assert_includes last_response.headers['location'], 'state=abc'
  end
end

describe 'OAuth token authorization_code grant' do
  include Rack::Test::Methods
  include OAuthTest

  it 'mints an access token that then authenticates an MCP call' do
    account, = make_account
    client = register_client
    verifier, challenge = pkce
    token_post(code_grant(client, mint_code(account, client, challenge).raw, verifier))
    assert_equal 200, last_response.status
    mcp_call(json_body['access_token'])
    assert_equal 200, last_response.status
    assert_includes last_response.body, account.to_s
  end
end

describe 'OAuth token PKCE enforcement' do
  include Rack::Test::Methods
  include OAuthTest

  it 'rejects a wrong PKCE verifier as invalid_grant' do
    account, = make_account
    client = register_client
    _, challenge = pkce
    token_post(code_grant(client, mint_code(account, client, challenge).raw, 'wrong-verifier'))
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth authorization code single use' do
  include Rack::Test::Methods
  include OAuthTest

  it 'refuses a second exchange of the same code' do
    account, = make_account
    client = register_client
    verifier, challenge = pkce
    grant = code_grant(client, mint_code(account, client, challenge).raw, verifier)
    token_post(grant)
    token_post(grant)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth token invalid codes' do
  include Rack::Test::Methods
  include OAuthTest

  it 'rejects an unknown authorization code' do
    client = register_client
    token_post(code_grant(client, 'no-such-code', 'v'))
    assert_equal 'invalid_grant', json_body['error']
  end

  it 'rejects an expired authorization code' do
    account, = make_account
    client = register_client
    verifier, challenge = pkce
    code = mint_code(account, client, challenge)
    code.record.update(expires_at: Time.now - 60)
    token_post(code_grant(client, code.raw, verifier))
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth token content type' do
  include Rack::Test::Methods
  include OAuthTest

  it 'rejects a non-form-encoded token request without a 415' do
    post 'http://localhost/token', { grant_type: 'refresh_token' }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 400, last_response.status
    assert_equal 'invalid_request', json_body['error']
  end
end

describe 'OAuth refresh token rotation' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    verifier, challenge = pkce
    token_post(code_grant(@client, mint_code(@account, @client, challenge).raw, verifier))
    @refresh = json_body['refresh_token']
  end

  it 'rotates to a new refresh token and mints a fresh access token' do
    token_post(grant_type: 'refresh_token', refresh_token: @refresh, client_id: @client.client_id)
    assert_equal 200, last_response.status
    refute_equal @refresh, json_body['refresh_token']
    refute_nil json_body['access_token']
  end

  it 'refuses reuse of a rotated refresh token as invalid_grant' do
    token_post(grant_type: 'refresh_token', refresh_token: @refresh, client_id: @client.client_id)
    token_post(grant_type: 'refresh_token', refresh_token: @refresh, client_id: @client.client_id)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth token audience enforcement' do
  include Rack::Test::Methods
  include OAuthTest

  it 'refuses an OAuth token whose resource is not this endpoint' do
    account, = make_account
    token = Tectonic::ApiToken.mint_oauth(account_id: account, scopes: ['read'],
                                          client_id: 'c', resource: 'https://elsewhere.example/mcp')
    mcp_call(token.raw)
    assert_equal 401, last_response.status
  end

  it 'accepts an OAuth token whose resource matches this endpoint' do
    account, = make_account
    token = Tectonic::ApiToken.mint_oauth(account_id: account, scopes: ['read'],
                                          client_id: 'c', resource: RESOURCE)
    mcp_call(token.raw)
    assert_equal 200, last_response.status
  end
end

describe 'MCP unauthorized challenge' do
  include Rack::Test::Methods
  include OAuthTest

  it 'sends a resource_metadata challenge with the 401' do
    mcp_call(nil)
    assert_equal 401, last_response.status
    assert_includes last_response.headers['www-authenticate'], '/.well-known/oauth-protected-resource'
  end
end

