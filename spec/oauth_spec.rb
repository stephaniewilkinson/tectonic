# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
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

  # Creates and logs in a fresh account, returning its id.
  def sign_in
    id, email, password = create_account
    login(email, password)
    id
  end

  # Registers a client and walks the authorization-code + PKCE flow for the
  # already-signed-in session, returning the token endpoint's JSON response.
  def issue_token(scope: %w[read write])
    client = register_client
    verifier, challenge = pkce
    code = authorize(client, challenge, scope:)
    exchange(client, code, verifier)
  end

  # Full flow: fresh account + client -> the token endpoint's JSON response.
  def access_token(scope: %w[read write])
    sign_in
    issue_token(scope:)
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

describe 'OAuth protected-resource metadata' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'advertises the MCP resource, its authorization server, and the scopes (RFC 9728)' do
    get '/.well-known/oauth-protected-resource'
    md = JSON.parse(last_response.body)
    assert_equal 200, last_response.status
    assert_equal OAuthFlow::RESOURCE, md['resource']
    assert_equal %w[read write], md['scopes_supported']
    assert md['authorization_servers'].is_a?(Array) && !md['authorization_servers'].empty?
  end
end

describe 'the resource server accepts authorization-server tokens' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'verifies an issued JWT and resolves it to the account and scopes' do
    account = sign_in
    token = issue_token['access_token']
    claims = Tectonic::MCP::AccessToken.verify(token)
    refute_nil claims, 'an authorization-server token must pass resource-server verification'
    context = Tectonic::MCP::RequestContext.from_claims(claims)
    assert_equal account, context.account_id
    assert_equal %w[read write], context.scopes
  end
end

describe 'the OAuth consent form refuses a forged submission' do
  include Rack::Test::Methods
  include OAuthFlow

  # Submitting this form is what grants a client access to the account, so a request
  # that fails the CSRF check has to be refused outright -- and refused as a refusal,
  # not as the 500 an uncaught exception would produce.
  it 'answers 403 and issues no code without a valid CSRF token' do
    sign_in
    client = register_client
    _, challenge = pkce
    post '/authorize', client_id: client['client_id'], redirect_uri: client['redirect_uris'].first,
                       response_type: 'code', code_challenge: challenge,
                       code_challenge_method: 'S256', scope: %w[read]

    assert_equal 403, last_response.status
    assert_nil last_response.headers['location']
  end
end

describe 'every response carries the baseline security headers' do
  include Rack::Test::Methods
  include OAuthFlow

  # The consent screen is the page worth framing over a decoy, since one click on it
  # hands out account access.
  it 'refuses to be framed on the authorize page' do
    sign_in
    client = register_client
    _, challenge = pkce
    get '/authorize', client_id: client['client_id'], redirect_uri: client['redirect_uris'].first,
                      response_type: 'code', code_challenge: challenge,
                      code_challenge_method: 'S256', scope: 'read'

    assert_equal 200, last_response.status
    assert_includes last_response.headers['Content-Security-Policy'], "frame-ancestors 'none'"
  end

  it 'sets the policy, nosniff, and a referrer policy on an ordinary page' do
    get '/welcome'
    assert_includes last_response.headers['Content-Security-Policy'], "frame-ancestors 'none'"
    assert_includes last_response.headers['Content-Security-Policy'], "object-src 'none'"
    assert_equal 'nosniff', last_response.headers['X-Content-Type-Options']
    assert_equal 'strict-origin-when-cross-origin', last_response.headers['Referrer-Policy']
  end
end

