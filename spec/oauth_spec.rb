# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require 'json'
require 'base64'
require 'digest'
require 'securerandom'
require 'stringio'
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

  # `warn` writes to $stderr, so the object is swapped rather than the file descriptor.
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  def pkce
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    [verifier, challenge]
  end

  # GETs the consent screen the way a user arriving from an LLM does.
  def consent_page(client, scope: %w[read write])
    _, challenge = pkce
    get '/authorize', client_id: client['client_id'], redirect_uri: client['redirect_uris'].first,
                      response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256',
                      scope: scope.join(' '), resource: RESOURCE
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

  # Presents a refresh token at the token endpoint the way a client does, as the
  # client the grant was issued to.
  def refresh(client, refresh_token)
    post '/token', { grant_type: 'refresh_token', refresh_token:,
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
    issue_token_for_client(scope:).last
  end

  # The same flow, returning the client alongside its token: a refresh has to be
  # presented by the client the grant belongs to, so both are needed together.
  def issue_token_for_client(scope: %w[read write])
    client = register_client
    verifier, challenge = pkce
    code = authorize(client, challenge, scope:)
    [client, exchange(client, code, verifier)]
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

  it 'registers a native client on the loopback port it happened to bind' do
    register_client(redirect_uri: 'http://127.0.0.1:53791/callback')
    assert_equal 201, last_response.status
  end

  # Registration itself stays open, but the callback is where the authorization code
  # is delivered: a client free to name any callback needs only one careless approval
  # on the consent screen to walk away with a code.
  it 'refuses a callback that is not on the allow-list, and stores no client' do
    registered = DB[:oauth_applications].count
    refusal = register_client(redirect_uri: 'https://evil.example/steal')

    assert_equal 400, last_response.status
    assert_equal 'invalid_redirect_uri', refusal['error']
    assert_equal registered, DB[:oauth_applications].count
  end
end

# The allow-list is a standing guess about what a vendor's connector will present, and
# being wrong shows up as somebody reporting that it would not connect. Reproducing that
# needs whatever subscription exposes the connector, so the refusal has to be legible
# from the one attempt that already happened.
describe 'a refused registration' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'says what was rejected, on stderr where the platform log keeps it' do
    logged = capture_stderr { register_client(redirect_uri: 'https://evil.example/steal?state=abc') }

    assert_includes logged, 'refused redirect_uri at registration'
    assert_includes logged, 'https://evil.example/steal'
    # The query is a client's own string and answers nothing about the callback shape.
    refute_includes logged, 'state=abc'
  end

  it 'counts them without writing a line for each' do
    logged = capture_stderr do
      body = { client_name: 'Many', redirect_uris: ['https://evil.example/a', 'https://evil.example/b'],
               grant_types: %w[authorization_code], token_endpoint_auth_method: 'none' }
      post '/register', body.to_json, json_headers
    end

    assert_includes logged, '(2 of 2 refused)'
    assert_equal(1, logged.lines.count { |line| line.include?('refused redirect_uri') })
  end

  it 'stays quiet when the callback is allowed' do
    assert_empty(capture_stderr { register_client })
  end
end

describe 'the unauthenticated registration endpoint' do
  include Rack::Test::Methods
  include OAuthFlow

  # Nothing else caps a request body, so without this an anonymous caller chooses how
  # much the process allocates on an endpoint that needs no credentials at all.
  it 'refuses a registration body past the size cap' do
    body = { client_name: 'A' * (17 * 1024), redirect_uris: ['https://claude.ai/api/mcp/auth_callback'] }
    post '/register', body.to_json, json_headers
    refusal = JSON.parse(last_response.body)

    assert_equal 400, last_response.status
    assert_equal 'invalid_client_metadata', refusal['error']
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

describe 'a replayed refresh token' do
  include Rack::Test::Methods
  include OAuthFlow

  # Rotation alone only detects the breach: the replayed token matches no live grant
  # and is refused, but the grant itself stays usable, so whoever rotated first keeps
  # the account. RFC 9700 section 4.14.2 requires the grant to die on detected reuse,
  # which is the only outcome that costs the thief anything.
  it 'revokes the grant, so the token that replaced it stops working' do
    sign_in
    client, token = issue_token_for_client
    stolen = token['refresh_token']

    thief = refresh(client, stolen)
    assert_equal 200, last_response.status, "the first rotation must succeed: #{thief.inspect}"

    replayed = refresh(client, stolen)
    assert_equal 400, last_response.status
    assert_equal 'invalid_grant', replayed['error']

    refresh(client, thief['refresh_token'])
    assert_equal 400, last_response.status, 'the rotated token must die with the grant'
  end

  # Reuse revocation reads the grant out of the token, so the token has to prove it
  # was issued here: otherwise anyone holding a client id could revoke a stranger's
  # access by presenting a made-up token that names a guessed grant.
  it 'is refused without revoking anything when the tag is forged' do
    sign_in
    client, token = issue_token_for_client
    application_id = DB[:oauth_applications].where(client_id: client['client_id']).get(:id)
    grant_id = DB[:oauth_grants].where(oauth_application_id: application_id).get(:id)

    refresh(client, "#{grant_id}~forged~forged")
    assert_equal 400, last_response.status

    rotated = refresh(client, token['refresh_token'])
    assert_equal 200, last_response.status, "the grant must survive a forged token: #{rotated.inspect}"
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

describe 'the OAuth consent screen' do
  include Rack::Test::Methods
  include OAuthFlow

  before do
    sign_in
    consent_page(register_client)
  end

  # One click here hands an API client the account, and the site layout would have
  # brought five third-party scripts to the page it happens on, any one of which could
  # rewrite the form under the user.
  it 'loads none of the site layout scripts' do
    assert_equal 200, last_response.status
    %w[tinyanalytics chartkick chart.umd date-fns htmx].each do |script|
      refute_includes last_response.body, script
    end
  end

  # form-action stays out: the consent POST is answered with a 302 to the client's
  # callback, and browsers disagree about whether it applies across a redirect.
  it 'carries a policy naming only the script origin it needs' do
    policy = last_response.headers['Content-Security-Policy']

    assert_includes policy, "default-src 'none'"
    assert_includes policy, 'script-src https://cdn.tailwindcss.com'
    assert_includes policy, "frame-ancestors 'none'"
    refute_includes policy, 'form-action'
  end
end

describe 'the OAuth consent screen still grants' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'issues a code that exchanges for a token' do
    sign_in
    client = register_client
    verifier, challenge = pkce
    code = authorize(client, challenge)

    assert code, 'the consent form must still submit and redirect with a code'
    assert exchange(client, code, verifier)['access_token']
  end
end

describe 'every response carries the baseline security headers' do
  include Rack::Test::Methods
  include OAuthFlow

  # The consent screen is the page worth framing over a decoy, since one click on it
  # hands out account access.
  it 'refuses to be framed on the authorize page' do
    sign_in
    consent_page(register_client)

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

