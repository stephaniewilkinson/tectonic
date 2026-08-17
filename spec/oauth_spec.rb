# frozen_string_literal: true

require_relative 'spec_helper'
require 'json'
require 'base64'
require 'digest'
require 'securerandom'
require 'bcrypt'

# The OAuth authorization server, driven through the Roda app with Rack::Test. The
# helpers walk the same path claude.ai does: register a client, log in, consent, and
# exchange the code (with PKCE) for a signed JWT access token.
module OAuthFlow
  RESOURCE = 'https://example.org/mcp'

  def app
    Tectonic
  end

  def json_headers
    { 'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json' }
  end

  def create_account(password: 'correcthorsebatterystaple')
    email = "#{SecureRandom.hex}@example.com"
    id = DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    [id, email, password]
  end

  def login(email, password)
    post '/login', { login: email, password: }.to_json, json_headers
  end

  def register_client(redirect_uri: 'https://claude.ai/api/mcp/auth_callback')
    body = { client_name: 'Claude', redirect_uris: [redirect_uri],
             grant_types: %w[authorization_code refresh_token], response_types: ['code'],
             token_endpoint_auth_method: 'none', scope: 'read write' }
    post '/register', body.to_json, json_headers
    JSON.parse(last_response.body)
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    [verifier, challenge]
  end

  # Runs the consent step: GET the authorize page, then POST it back with the CSRF
  # token and the granted scopes. Returns the authorization code from the redirect.
  def authorize(client, challenge, scope: %w[read write])
    query = { client_id: client['client_id'], redirect_uri: client['redirect_uris'].first,
              response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256',
              scope: scope.join(' '), resource: RESOURCE }
    get '/authorize', query
    csrf = last_response.body[/name="_csrf"\s+value="([^"]+)"/, 1]
    form = query.except(:scope).merge('_csrf' => csrf, 'scope' => scope)
    post '/authorize', form
    last_response.headers['location'].to_s[/code=([^&]+)/, 1]
  end

  def exchange(client, code, verifier)
    post '/token', { grant_type: 'authorization_code', code:,
                     redirect_uri: client['redirect_uris'].first, code_verifier: verifier,
                     client_id: client['client_id'], resource: RESOURCE }
    JSON.parse(last_response.body)
  end

  # Full flow: fresh account + client -> a signed JWT access token payload string.
  def access_token(scope: %w[read write])
    _id, email, password = create_account
    login(email, password)
    client = register_client
    verifier, challenge = pkce
    code = authorize(client, challenge, scope:)
    exchange(client, code, verifier)
  end
end

describe 'OAuth authorization server metadata' do
  include Rack::Test::Methods
  include OAuthFlow

  before { get '/.well-known/oauth-authorization-server' }

  it 'advertises the issuer and endpoints' do
    md = JSON.parse(last_response.body)
    assert_equal 200, last_response.status
    assert md['issuer']
    assert md['authorization_endpoint'] && md['token_endpoint'] && md['registration_endpoint']
  end

  it 'offers only the read and write scopes and S256 PKCE' do
    md = JSON.parse(last_response.body)
    assert_equal %w[read write], md['scopes_supported']
    assert_equal ['S256'], md['code_challenge_methods_supported']
  end
end

describe 'OAuth dynamic client registration' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'registers a public PKCE client with no prior account' do
    client = register_client
    assert_equal 201, last_response.status
    assert client['client_id']
    assert_equal 'none', client['token_endpoint_auth_method']
  end
end

describe 'the authorization code + PKCE flow' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'issues a JWT access token bound to the account, scopes, and MCP audience' do
    token = access_token
    assert token['access_token'], "no access_token in #{token.inspect}"
    payload, = JWT.decode(token['access_token'], Tectonic::OAuthKeys.public_key, true, algorithm: 'RS256')
    assert_equal 'read write', payload['scope']
    assert_includes Array(payload['aud']), OAuthFlow::RESOURCE
    assert payload['sub'], 'expected a subject (account) claim'
  end
end

