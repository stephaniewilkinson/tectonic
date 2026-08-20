# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/oauth/retention'
require 'bcrypt'
require 'cgi'
require 'securerandom'
require 'digest'
require 'base64'
require 'json'

# The public origin (and token audience) the app derives its OAuth surface from, and the
# one non-loopback callback claude.ai uses.
RESOURCE = Tectonic::MCP::Config.resource_url
CALLBACK = 'https://claude.ai/api/mcp/auth_callback'
# The redirect_uri policy under test on its own, named short because every assertion
# about the allow-list reads better as a sentence about matching.
POLICY = Tectonic::OAuth::RedirectUri

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

  # A code bound the way a validated authorize request would have bound it. `scopes`
  # matters: offline_access is what buys a refresh token, so a test that wants one has
  # to ask for it exactly as a user consenting to it would.
  def mint_code(account_id, client, challenge, scopes: %w[read], redirect_uri: CALLBACK)
    request = Tectonic::OAuth::AuthorizeRequest.new(
      client:, client_id: client.client_id, redirect_uri:, scopes:,
      code_challenge: challenge, code_challenge_method: 'S256', resource: RESOURCE, state: nil
    )
    Tectonic::OAuthAuthorizationCode.mint(request:, account_id:)
  end

  # Runs a full code grant and returns the parsed token response.
  def granted(account_id, client, scopes: %w[read offline_access])
    verifier, challenge = pkce
    code = mint_code(account_id, client, challenge, scopes:)
    token_post(code_grant(client, code.raw, verifier))
    json_body
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

  # Applies the retention policy with a cutoff `days` in the past.
  def prune(days)
    Tectonic::OAuth::Retention.prune(DB, Time.now - (days * 86_400))
  end

  # A grant whose chain has been rotated `depth` times, returning [grant, live token row].
  def chain(depth)
    grant = new_grant
    minted = Tectonic::OAuthRefreshToken.mint(grant:, access_token_id: first_access(grant).id)
    (depth - 1).times { minted = Tectonic::OAuthRefreshToken[minted.record.id].rotate![1] }
    [grant, Tectonic::OAuthRefreshToken[minted.record.id]]
  end

  def new_grant
    account, = make_account
    Tectonic::OAuth::Grant.start(account_id: account, client_id: register_client.client_id,
                                 scopes: %w[read offline_access], resource: RESOURCE)
  end

  def first_access(grant)
    Tectonic::ApiToken.mint_oauth(account_id: grant.account_id, scopes: grant.scopes,
                                  client_id: grant.client_id, resource: grant.resource).record
  end

  # Anything belonging to a grant that is still usable: the count revocation must drive to
  # zero, counting both the refresh rows and the access tokens they minted.
  def survivors(grant_id)
    ids = Tectonic::OAuthRefreshToken.where(grant_id:).select_map(:access_token_id).compact
    Tectonic::ApiToken.where(id: ids, revoked_at: nil).count +
      Tectonic::OAuthRefreshToken.where(grant_id:, revoked_at: nil).count
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
    @refresh = granted(@account, @client)['refresh_token']
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

describe 'OAuth redirect_uri matching' do
  it 'forgives only the port between two loopback URIs' do
    assert POLICY.match?('http://127.0.0.1/cb', 'http://127.0.0.1:5173/cb')
    assert POLICY.match?('http://127.0.0.1:1/cb', 'http://127.0.0.1:2/cb')
  end

  it 'does not let port-agnostic matching become path, host, or query agnostic' do
    refute POLICY.match?('http://127.0.0.1/cb', 'http://127.0.0.1:5173/other')
    refute POLICY.match?('http://127.0.0.1/cb', 'http://localhost:5173/cb')
    refute POLICY.match?('http://127.0.0.1/cb', 'http://127.0.0.1:5173/cb?next=x')
    refute POLICY.match?('http://127.0.0.1/cb', 'http://127.0.0.1/cb/')
  end

  it 'matches a non-loopback URI only exactly' do
    assert POLICY.match?(CALLBACK, CALLBACK)
    refute POLICY.match?(CALLBACK, "#{CALLBACK}/x")
    refute POLICY.match?(CALLBACK, "#{CALLBACK}?x=1")
    refute POLICY.match?(CALLBACK, 'https://claude.ai.evil.example/api/mcp/auth_callback')
  end
end

describe 'OAuth redirect_uri registration policy' do
  it 'accepts only the claude.ai callback and loopback URIs' do
    assert POLICY.acceptable?(CALLBACK)
    assert POLICY.acceptable?('http://localhost:8000/cb')
    assert POLICY.acceptable?('http://[::1]:8000/cb')
    refute POLICY.acceptable?('https://evil.example/cb')
    refute POLICY.acceptable?('http://127.0.0.1.evil.example/cb')
  end

  it 'refuses a URI carrying a fragment or an unbounded length' do
    refute POLICY.acceptable?('http://127.0.0.1/cb#frag')
    refute POLICY.acceptable?('http://127.0.0.1/cb#')
    refute POLICY.acceptable?("http://127.0.0.1/#{'a' * 600}")
  end

  it 'treats a userinfo host as the real host, not a loopback' do
    refute POLICY.acceptable?('http://127.0.0.1@evil.example/cb')
    refute POLICY.loopback?('http://127.0.0.1@evil.example/cb')
  end
end

describe 'OAuth authorize redirect_uri binding' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, email, password = make_account
    @client = register_client
    login(email, password)
  end

  def authorize(redirect_uri)
    _, challenge = pkce
    get 'http://localhost/authorize', response_type: 'code', client_id: @client.client_id,
                                      redirect_uri:, code_challenge: challenge,
                                      code_challenge_method: 'S256', resource: RESOURCE
  end

  it 'refuses a redirect_uri the client never registered, without redirecting' do
    authorize('https://evil.example/cb')
    assert_equal 400, last_response.status
    assert_nil last_response.headers['Location']
  end

  it 'refuses a near-miss of the registered callback' do
    ["#{CALLBACK}/x", "#{CALLBACK}?x=1", 'https://claude.ai.evil.example/api/mcp/auth_callback'].each do |uri|
      authorize(uri)
      assert_equal 400, last_response.status, "expected #{uri} to be refused"
      assert_nil last_response.headers['Location']
    end
  end
end

describe 'OAuth token endpoint re-binding' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    @verifier, @challenge = pkce
  end

  it 'refuses a redirect_uri that differs from the one the code was bound to' do
    code = mint_code(@account, @client, @challenge)
    token_post(code_grant(@client, code.raw, @verifier).merge(redirect_uri: 'http://127.0.0.1/cb'))
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end

  it 'refuses a client_id that differs from the one the code was bound to' do
    code = mint_code(@account, @client, @challenge)
    token_post(code_grant(@client, code.raw, @verifier).merge(client_id: register_client.client_id))
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end

  it 'refuses a resource that differs from the one the code was bound to' do
    code = mint_code(@account, @client, @challenge)
    token_post(code_grant(@client, code.raw, @verifier).merge(resource: 'https://elsewhere.example/mcp'))
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth offline_access gates the refresh token' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
  end

  it 'issues no refresh token when offline_access was not granted' do
    body = granted(@account, @client, scopes: %w[read])
    assert_equal 200, last_response.status
    refute_nil body['access_token']
    assert_nil body['refresh_token']
    assert_equal 'read', body['scope']
  end

  it 'issues a refresh token when offline_access was granted' do
    body = granted(@account, @client, scopes: %w[read offline_access])
    refute_nil body['refresh_token']
  end
end

describe 'OAuth refresh token reuse revokes the whole grant' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    first = granted(@account, @client)
    @stolen = first['refresh_token']
    token_post(grant_type: 'refresh_token', refresh_token: @stolen, client_id: @client.client_id)
    @rotated = json_body
  end

  it 'kills the successor refresh token when the spent one is replayed' do
    token_post(grant_type: 'refresh_token', refresh_token: @stolen, client_id: @client.client_id)
    assert_equal 400, last_response.status

    token_post(grant_type: 'refresh_token', refresh_token: @rotated['refresh_token'],
               client_id: @client.client_id)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end

  it 'kills the access tokens the chain minted' do
    mcp_call(@rotated['access_token'])
    assert_equal 200, last_response.status

    token_post(grant_type: 'refresh_token', refresh_token: @stolen, client_id: @client.client_id)
    mcp_call(@rotated['access_token'])
    assert_equal 401, last_response.status
  end
end

describe 'OAuth revocation endpoint' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    @tokens = granted(@account, @client)
  end

  def revoke(token)
    post 'http://localhost/revoke', { token: }
  end

  it 'revoking the refresh token also stops its access token' do
    revoke(@tokens['refresh_token'])
    assert_equal 200, last_response.status

    mcp_call(@tokens['access_token'])
    assert_equal 401, last_response.status
  end

  it 'revoking the access token also stops the refresh chain' do
    revoke(@tokens['access_token'])

    token_post(grant_type: 'refresh_token', refresh_token: @tokens['refresh_token'],
               client_id: @client.client_id)
    assert_equal 400, last_response.status
  end
end

describe 'OAuth revocation discloses nothing' do
  include Rack::Test::Methods
  include OAuthTest

  it 'answers 200 for an unknown token so it cannot be used to probe' do
    post 'http://localhost/revoke', { token: 'not-a-real-token' }
    assert_equal 200, last_response.status
  end
end

describe 'OAuth access token revocation cascades' do
  include Rack::Test::Methods
  include OAuthTest

  it 'stops the refresh token when the operator revokes the access token it minted' do
    account, = make_account
    client = register_client
    tokens = granted(account, client)

    Tectonic::ApiToken.where(account_id: account).each(&:revoke!)

    token_post(grant_type: 'refresh_token', refresh_token: tokens['refresh_token'],
               client_id: client.client_id)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end
end

describe 'OAuth grant absolute lifetime' do
  include Rack::Test::Methods
  include OAuthTest

  it 'refuses a refresh token past its grant deadline however fresh the token itself is' do
    account, = make_account
    client = register_client
    raw = granted(account, client)['refresh_token']
    Tectonic::OAuthRefreshToken.where(account_id: account).update(chain_expires_at: Time.now - 60)

    token_post(grant_type: 'refresh_token', refresh_token: raw, client_id: client.client_id)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', json_body['error']
  end

  it 'carries the deadline forward unchanged across a rotation' do
    account, = make_account
    client = register_client
    raw = granted(account, client)['refresh_token']
    original = Tectonic::OAuthRefreshToken.where(account_id: account).first

    token_post(grant_type: 'refresh_token', refresh_token: raw, client_id: client.client_id)
    successor = Tectonic::OAuthRefreshToken[original.refresh.replaced_by_id]

    assert_equal original.grant_id, successor.grant_id
    assert_in_delta original.chain_expires_at, successor.chain_expires_at, 1
  end
end

describe 'OAuth consent screen guards' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, @email, @password = make_account
    @client = register_client
    _, @challenge = pkce
  end

  def approve(params)
    post 'http://localhost/authorize', {
      response_type: 'code', client_id: @client.client_id, redirect_uri: CALLBACK,
      scope: 'read', code_challenge: @challenge, code_challenge_method: 'S256',
      resource: RESOURCE
    }.merge(params)
  end

  it 'refuses a logged-in approval carrying no CSRF token, and mints no code' do
    login(@email, @password)
    approve({})
    assert_equal 403, last_response.status
    assert_equal 0, Tectonic::OAuthAuthorizationCode.where(account_id: @account).count
  end

  it 'refuses an unauthenticated approval with a forged token, and mints no code' do
    approve('_csrf' => 'forged')
    assert_equal 403, last_response.status
    assert_equal 0, Tectonic::OAuthAuthorizationCode.where(account_id: @account).count
  end
end

describe 'OAuth interrupted authorize resumes after login' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, @email, @password = make_account
    @client = register_client
    _, @challenge = pkce
  end

  def start_authorize
    get 'http://localhost/authorize', response_type: 'code', client_id: @client.client_id,
                                      redirect_uri: CALLBACK, code_challenge: @challenge,
                                      code_challenge_method: 'S256', resource: RESOURCE
  end

  it 'sends an unauthenticated authorize request to log in rather than to consent' do
    start_authorize
    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], '/login'
  end

  it 'returns an interrupted authorize request to the client after login' do
    start_authorize
    assert_includes last_response.headers['Location'], '/login'

    login(@email, @password)
    assert_includes last_response.headers['Location'], '/authorize'
  end
end

describe 'OAuth registration input bounds' do
  include Rack::Test::Methods
  include OAuthTest

  def register(body)
    post 'http://localhost/register', body.is_a?(String) ? body : body.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
  end

  it 'refuses more redirect_uris than it will store' do
    register(redirect_uris: Array.new(11) { |i| "http://localhost/cb#{i}" })
    assert_equal 400, last_response.status
    assert_equal 'invalid_client_metadata', json_body['error']
  end

  it 'refuses an unbounded client_name' do
    register(redirect_uris: [CALLBACK], client_name: 'A' * 201)
    assert_equal 400, last_response.status
  end

  it 'refuses a body larger than the cap without raising' do
    register(redirect_uris: [CALLBACK], client_name: 'A' * 20_000)
    assert_equal 400, last_response.status
    assert_equal 'invalid_client_metadata', json_body['error']
  end
end

describe 'OAuth registration input typing' do
  include Rack::Test::Methods
  include OAuthTest

  def register(body)
    post 'http://localhost/register', body.is_a?(String) ? body : body.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
  end

  it 'refuses valid JSON that is not an object rather than returning a 500' do
    ['[]', 'null', '123', 'true', '"str"'].each do |body|
      register(body)
      assert_equal 400, last_response.status, "expected #{body} to be a 400"
    end
  end

  it 'refuses non-string redirect_uris rather than coercing them' do
    register(redirect_uris: [123, { 'a' => 'b' }])
    assert_equal 400, last_response.status
  end

  it 'refuses a client_name that is not a string' do
    register(redirect_uris: [CALLBACK], client_name: { 'a' => 'b' })
    assert_equal 400, last_response.status
  end
end

describe 'OAuth endpoints refuse structured params without raising' do
  include Rack::Test::Methods
  include OAuthTest

  it 'answers a token request whose params are arrays with an RFC error' do
    post 'http://localhost/token', 'grant_type=authorization_code&code[]=a&client_id[]=b'
    assert_equal 400, last_response.status
    assert_equal 'invalid_request', json_body['error']
  end

  it 'answers a refresh request whose token is a hash with an RFC error' do
    post 'http://localhost/token', 'grant_type=refresh_token&refresh_token[a]=b'
    assert_equal 400, last_response.status
    assert_equal 'invalid_request', json_body['error']
  end

  it 'answers an authorize request whose params are arrays without raising' do
    get 'http://localhost/authorize?response_type=code&client_id[]=a&redirect_uri[]=b'
    assert_equal 400, last_response.status
  end

  it 'answers a revocation whose token is an array without raising' do
    post 'http://localhost/revoke', 'token[]=a'
    assert_equal 200, last_response.status
  end
end

describe 'OAuth resource (audience) validation' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, email, password = make_account
    @client = register_client
    login(email, password)
    _, @challenge = pkce
  end

  def authorize(params)
    get 'http://localhost/authorize', {
      response_type: 'code', client_id: @client.client_id, redirect_uri: CALLBACK,
      code_challenge: @challenge, code_challenge_method: 'S256'
    }.merge(params)
  end

  it 'refuses an audience this server does not protect' do
    authorize(resource: 'https://elsewhere.example/mcp')
    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], 'error=invalid_target'
  end

  it 'accepts its own resource' do
    authorize(resource: RESOURCE)
    assert_equal 200, last_response.status
  end
end

describe 'OAuth default audience' do
  include Rack::Test::Methods
  include OAuthTest

  it 'binds a request that names no resource to this endpoint, so its token works' do
    account, = make_account
    client = register_client
    verifier, challenge = pkce
    request = Tectonic::OAuth::Authorization.validate(
      'response_type' => 'code', 'client_id' => client.client_id, 'redirect_uri' => CALLBACK,
      'code_challenge' => challenge, 'code_challenge_method' => 'S256'
    ).request
    assert_equal RESOURCE, request.resource

    code = Tectonic::OAuthAuthorizationCode.mint(request:, account_id: account)
    token_post(code_grant(client, code.raw, verifier).except(:resource))
    mcp_call(json_body['access_token'])
    assert_equal 200, last_response.status
  end
end

describe 'OAuth family revocation is atomic' do
  include Rack::Test::Methods
  include OAuthTest

  it 'leaves nothing live when a rotation commits during the sweep' do
    5.times do |i|
      grant, live = chain(8)
      rotate = Thread.new { sleep(i * 0.002) && live.rotate! }
      sweep = Thread.new { Tectonic::OAuthRefreshToken.revoke_family!(grant.id) }
      [rotate, sweep].each(&:join)
      assert_equal 0, survivors(grant.id), "a token survived revocation on iteration #{i}"
    end
  end

  it 'does no work for a grant that is already dead, so a replay cannot amplify' do
    grant, = chain(3)
    assert_operator Tectonic::OAuthRefreshToken.revoke_family!(grant.id), :>, 0
    assert_equal 0, Tectonic::OAuthRefreshToken.revoke_family!(grant.id)
  end

  it 'revokes every access token the chain minted, not only the newest' do
    grant, = chain(4)
    Tectonic::OAuthRefreshToken.revoke_family!(grant.id)
    assert_equal 0, survivors(grant.id)
  end
end

describe 'OAuth endpoints survive unreadable parameters' do
  include Rack::Test::Methods
  include OAuthTest

  it 'answers a bad percent-escape with an RFC error rather than raising' do
    post 'http://localhost/token', 'grant_type=refresh_token&refresh_token=%'
    assert_equal 400, last_response.status
    assert_equal 'invalid_request', json_body['error']
  end

  it 'answers a bad percent-escape on revoke with 200 rather than raising' do
    post 'http://localhost/revoke', 'token=%'
    assert_equal 200, last_response.status
  end

  # Built as a raw env because Rack::Test parses the URI itself and would refuse to send
  # this; a real client puts the broken escape straight on the wire.
  it 'answers a bad percent-escape on authorize with the error page rather than raising' do
    env = Rack::MockRequest.env_for('http://localhost/authorize')
    env['QUERY_STRING'] = 'client_id=%zz&response_type=code'
    status, = app.call(env)
    assert_equal 400, status
  end
end

describe 'OAuth refuses a structured scope rather than widening the grant' do
  include Rack::Test::Methods
  include OAuthTest

  it 'does not read scope[]=read as "scope omitted"' do
    account, email, password = make_account
    client = register_client
    login(email, password)
    _, challenge = pkce
    get 'http://localhost/authorize?response_type=code&client_id=' \
        "#{client.client_id}&redirect_uri=#{CGI.escape(CALLBACK)}&scope[]=read" \
        "&code_challenge=#{challenge}&code_challenge_method=S256"
    assert_equal 400, last_response.status
    assert_equal 0, Tectonic::OAuthAuthorizationCode.where(account_id: account).count
  end
end

describe 'OAuth registration refuses an unusable callback' do
  include Rack::Test::Methods
  include OAuthTest

  it 'refuses a redirect_uri whose query holds a broken percent-escape' do
    refute POLICY.acceptable?('http://127.0.0.1/cb?a=%')
    post 'http://localhost/register', { redirect_uris: ['http://127.0.0.1/cb?a=%'] }.to_json,
         { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 400, last_response.status
  end
end

describe 'OAuth retention keeps what revocation needs' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    @tokens = granted(@account, @client)
    token_post(grant_type: 'refresh_token', refresh_token: @tokens['refresh_token'],
               client_id: @client.client_id)
    @rotated = json_body['refresh_token']
  end

  it 'keeps rotated-out tokens of a live grant, so reuse detection still fires' do
    prune(0)

    token_post(grant_type: 'refresh_token', refresh_token: @tokens['refresh_token'],
               client_id: @client.client_id)
    assert_equal 400, last_response.status

    token_post(grant_type: 'refresh_token', refresh_token: @rotated, client_id: @client.client_id)
    assert_equal 400, last_response.status, 'the successor should have died with the family'
  end

  it 'deletes a chain once its grant is past its absolute deadline' do
    Tectonic::OAuthRefreshToken.where(account_id: @account).update(chain_expires_at: Time.now - 86_400)
    assert_operator prune(0)[:refresh_tokens], :>, 0
    assert_equal 0, Tectonic::OAuthRefreshToken.where(account_id: @account).count
  end
end

describe 'OAuth retention keeps a client with a live token' do
  include Rack::Test::Methods
  include OAuthTest

  before do
    @account, = make_account
    @client = register_client
    @tokens = granted(@account, @client)
  end

  it 'keeps a client whose access token is still live even after its code expires' do
    aged = Time.now - 86_400
    Tectonic::OAuthAuthorizationCode.where(account_id: @account).update(expires_at: aged)
    Tectonic::OAuthRefreshToken.where(account_id: @account).delete
    DB[:oauth_clients].where(client_id: @client.client_id).update(created_at: aged)
    prune(0)

    assert Tectonic::OAuthClient.locate(@client.client_id), 'a live token lost its client'
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

