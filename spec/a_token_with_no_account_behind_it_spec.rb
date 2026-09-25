# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'oauth_spec' # register, json_headers; idempotent require
require_relative 'mcp_spec' # grant_claims, mcp_headers; idempotent require

# Found in a security pass, 2026-09-25. Registration is open to anybody, and the
# client-credentials grant was enabled though nothing used it -- so a stranger could register a
# client, mint a valid token with no account behind it, and call the connector as "no account".
# Library movements are the rows with no account: create_exercise from that token wrote a
# movement into the library every lifter shares. Production was checked and never hit.
describe 'a stranger asking for a token without an account' do
  include Rack::Test::Methods
  include OAuthFlow

  it 'is not issued one' do
    post '/register', { client_name: 'Probe', redirect_uris: ['https://claude.ai/api/mcp/auth_callback'],
                        grant_types: %w[client_credentials], response_types: [],
                        token_endpoint_auth_method: 'client_secret_post', scope: 'read write' }.to_json, json_headers
    client = JSON.parse(last_response.body)
    post '/token', { grant_type: 'client_credentials', client_id: client['client_id'].to_s,
                     client_secret: client['client_secret'].to_s, scope: 'read write' }

    refute_includes last_response.body, 'access_token'
  end
end

# And the door, in case anything ever issues one again: a signed, live token whose subject is not
# an account is refused before any tool runs, so no tool can be written that forgets to check.
describe 'the connector, handed a valid token that names no account' do
  include Rack::Test::Methods

  def app = Tectonic::MCP.rack_app

  it 'refuses it, and the library is untouched' do
    application = new_oauth_application
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x')
    grant = new_grant(account_id, application, %w[read write])
    claims = grant_claims(account_id, application, %w[read write], grant).merge(sub: application.client_id)
    raw = JWT.encode(claims, Tectonic::OAuthKeys.private_key, Tectonic::OAuthKeys::ALGORITHM)
    library = DB[:exercises].where(account_id: nil).count
    post 'http://localhost/mcp', { jsonrpc: '2.0', id: 1, method: 'tools/call',
                                   params: { name: 'create_exercise', arguments: { name: 'Injected' } } }.to_json,
         mcp_headers(raw)

    assert_equal 401, last_response.status
    assert_equal library, DB[:exercises].where(account_id: nil).count
  end
end

