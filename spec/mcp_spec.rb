# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'jwt'
require 'openssl'

# The MCP endpoint mounted as its own Rack app. The transport ignores the request
# path, so posting to /mcp on localhost keeps the default loopback host allowed. A
# test can swap in a custom-tool app by setting @app first.
def app
  @app || Tectonic::MCP.rack_app
end

# The auth middleware in front of a transport exposing exactly `tools`, so the write
# path can be driven end to end without shipping a real write tool.
def app_with(*tools)
  Tectonic::MCP::Auth.new(->(env) { probe_transport(tools, env).call(env) })
end

def probe_transport(tools, env)
  context = env.fetch(Tectonic::MCP::Auth::CONTEXT_KEY)
  server = MCP::Server.new(name: 'Test', version: '0', tools:, server_context: context)
  MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
end

def new_account
  DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x', created_on: Time.now)
end

# A registered OAuth client (the "LLM") to attribute a test token to. Fresh per mint so
# each token maps to its own application id, the way real distinct clients would.
def new_oauth_application(name: 'Test LLM')
  Tectonic::OAuthApplication.create(name:, client_id: SecureRandom.uuid, client_secret: SecureRandom.hex,
                                    redirect_uri: 'https://example.com/cb', scopes: 'read write')
end

Minted = Struct.new(:raw, :account_id, :application_id, :grant_id)

# Signs a JWT access token exactly as the authorization server does, so the resource
# server accepts it: the account in `sub`, the client in `client_id`, the granted
# scopes, this MCP endpoint as the audience, and the grant it was issued against in
# `gid`. The grant row is real, because the resource server checks it is still live --
# a token naming no live grant is refused, which is how revocation reaches tokens
# already issued. The keyword overrides drive the rejection paths (a past `exp`, a
# foreign `aud`, a wrong signing `key`); revoking the returned grant_id covers the rest.
def mint(scopes: ['read'], account_id: nil, exp: nil, aud: nil, key: nil)
  account_id ||= new_account
  application = new_oauth_application
  grant_id = new_grant(account_id, application, scopes)
  claims = grant_claims(account_id, application, scopes, grant_id)
  claims[:aud] = aud if aud
  claims[:exp] = exp if exp
  raw = JWT.encode(claims, key || Tectonic::OAuthKeys.private_key, Tectonic::OAuthKeys::ALGORITHM)
  Minted.new(raw, account_id, application.id, grant_id)
end

# The claims the authorization server signs for a granted token.
def grant_claims(account_id, application, scopes, grant_id)
  { sub: account_id.to_s, client_id: application.client_id, gid: grant_id,
    scope: Array(scopes).join(' '), aud: [Tectonic::MCP::Config.resource_url],
    iat: Time.now.to_i, exp: Time.now.to_i + 3600 }
end

# The oauth_grants row a token is issued against, as rodauth-oauth would have written it.
def new_grant(account_id, application, scopes)
  DB[:oauth_grants].insert(account_id:, oauth_application_id: application.id,
                           scopes: Array(scopes).join(' '), expires_in: Time.now + 3600)
end

def mcp_headers(raw)
  headers = { 'CONTENT_TYPE' => 'application/json', 'HTTP_ACCEPT' => 'application/json, text/event-stream' }
  raw ? headers.merge('HTTP_AUTHORIZATION' => "Bearer #{raw}") : headers
end

def call_tool(name, raw:, arguments: {}, host: 'localhost')
  body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name:, arguments: } }
  post "http://#{host}/mcp", body.to_json, mcp_headers(raw)
  last_response
end

def tool_result
  JSON.parse(last_response.body).fetch('result')
end

# Test-only write tool: exercises scope, kill switch, and audit. `note: 'boom'`
# passes the schema and then raises, so the failure path can be audited.
class AuditProbeTool < Tectonic::MCP::Tool
  tool_name 'audit_probe'
  description 'Test-only write tool.'
  scope :write
  input_schema(type: 'object', properties: { note: { type: 'string' } }, required: ['note'])

  def self.perform(arguments:, **)
    raise 'boom' if arguments[:note] == 'boom'

    ok("noted: #{arguments[:note]}")
  end
end

# Test-only read tool that accepts an account_id argument and ignores it, echoing the
# account the context actually resolved to.
class ScopeProbeTool < Tectonic::MCP::Tool
  tool_name 'scope_probe'
  description 'Test-only read tool.'
  scope :read
  input_schema(type: 'object', properties: { account_id: { type: 'integer' } })

  def self.perform(context:, arguments:)
    ok(context.account_id.to_s, structured: { resolved: context.account_id, argument: arguments[:account_id] })
  end
end

describe 'MCP bearer authentication' do
  include Rack::Test::Methods

  it 'rejects a request with no Authorization header' do
    assert_equal 401, call_tool('whoami', raw: nil).status
  end

  it 'rejects a malformed Authorization header' do
    post 'http://localhost/mcp', '{}', mcp_headers(nil).merge('HTTP_AUTHORIZATION' => 'Basic zzz')
    assert_equal 401, last_response.status
  end

  it 'rejects an unknown token' do
    assert_equal 401, call_tool('whoami', raw: SecureRandom.urlsafe_base64(32)).status
  end

  it 'rejects an expired token' do
    raw = mint(exp: Time.now.to_i - 60).raw
    assert_equal 401, call_tool('whoami', raw:).status
  end

  it 'rejects a token signed by an unknown key' do
    raw = mint(key: OpenSSL::PKey::RSA.generate(2048)).raw
    assert_equal 401, call_tool('whoami', raw:).status
  end

  it 'rejects a token minted for another audience' do
    raw = mint(aud: ['https://someone-else.example/mcp']).raw
    assert_equal 401, call_tool('whoami', raw:).status
  end
end

# Revoking a grant has to reach the tokens it already issued. A JWT is valid on its
# signature alone, so without a grant check a stolen token keeps working for its full
# hour after the grant behind it was killed.
describe 'MCP tokens die with their grant' do
  include Rack::Test::Methods

  it 'rejects a token whose grant was revoked after it was issued' do
    minted = mint
    assert_equal 200, call_tool('whoami', raw: minted.raw).status

    DB[:oauth_grants].where(id: minted.grant_id).update(revoked_at: Time.now)
    assert_equal 401, call_tool('whoami', raw: minted.raw).status
  end

  it 'rejects a token that names no grant at all' do
    claims = JWT.decode(mint.raw, Tectonic::OAuthKeys.public_key, false).first.except('gid')
    untagged = JWT.encode(claims, Tectonic::OAuthKeys.private_key, Tectonic::OAuthKeys::ALGORITHM)
    assert_equal 401, call_tool('whoami', raw: untagged).status
  end
end

# Somebody who typed the address into a browser instead of giving it to an assistant.
# The status and the challenge are unchanged; only what a human is shown differs.
describe 'the MCP endpoint in a browser' do
  include Rack::Test::Methods

  def browse
    get 'http://localhost/mcp', {}, { 'HTTP_ACCEPT' => 'text/html,application/xhtml+xml' }
  end

  it 'answers a browser with a page rather than a wall of JSON' do
    browse
    assert_equal 401, last_response.status
    assert_includes last_response.headers['content-type'], 'text/html'
    assert_includes last_response.body, 'This is the MCP endpoint'
    assert_includes last_response.body, '/connections'
  end

  it 'still carries the challenge a client needs to discover the authorization server' do
    browse
    assert_includes last_response.headers['www-authenticate'], 'resource_metadata='
  end

  # A client speaking the protocol must be unaffected: it posts, asks for JSON, and gets
  # the JSON-RPC error it can act on.
  it 'answers a protocol client with JSON as before' do
    assert_equal 401, call_tool('whoami', raw: nil).status
    assert_includes last_response.headers['content-type'], 'application/json'
    assert_includes last_response.body, 'jsonrpc'
  end

  # A browser carrying a bad token is a client, not a visitor: it gets the error.
  it 'does not sign-post a request that presented a token' do
    get 'http://localhost/mcp', {}, { 'HTTP_ACCEPT' => 'text/html',
                                      'HTTP_AUTHORIZATION' => 'Bearer nonsense' }
    assert_includes last_response.headers['content-type'], 'application/json'
  end
end

describe 'MCP DNS-rebinding protection' do
  include Rack::Test::Methods

  it 'rejects a request whose Host is not allow-listed' do
    raw = mint.raw
    assert_equal 403, call_tool('whoami', raw:, host: 'evil.example.com').status
  end

  it 'rejects a browser request from a foreign Origin' do
    raw = mint.raw
    env = mcp_headers(raw).merge('HTTP_ORIGIN' => 'http://evil.example.com')
    post 'http://localhost/mcp', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', env
    assert_equal 403, last_response.status
  end
end

describe 'the whoami tool' do
  include Rack::Test::Methods

  it 'reports the resolved account id, email, and scopes' do
    account = new_account
    raw = mint(scopes: %w[read write], account_id: account).raw
    structured = call_tool('whoami', raw:) && tool_result['structuredContent']
    assert_equal account, structured['account_id']
    assert_equal %w[read write], structured['scopes']
    assert_includes structured['email'], '@example.com'
  end

  it 'resolves each token to its own account' do
    first = mint.account_id
    second_raw = mint.raw
    call_tool('whoami', raw: second_raw)
    refute_equal first, tool_result['structuredContent']['account_id']
  end
end

describe 'MCP account scoping' do
  include Rack::Test::Methods

  before { @app = app_with(ScopeProbeTool) }

  it 'ignores an account_id argument and uses the resolved account' do
    account = new_account
    other = new_account
    raw = mint(account_id: account).raw
    call_tool('scope_probe', raw:, arguments: { account_id: other })
    structured = tool_result['structuredContent']
    assert_equal account, structured['resolved']
    assert_equal other, structured['argument']
  end
end

describe 'MCP scope enforcement' do
  include Rack::Test::Methods

  before { @app = app_with(AuditProbeTool) }

  it 'refuses a write tool for a read-only token' do
    raw = mint(scopes: ['read']).raw
    call_tool('audit_probe', raw:, arguments: { note: 'hi' })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), "needs the 'write' scope"
  end

  it 'audits the refusal of a write tool' do
    token = mint(scopes: ['read'])
    call_tool('audit_probe', raw: token.raw, arguments: { note: 'hi' })
    row = Tectonic::McpAuditLog.where(oauth_application_id: token.application_id).first
    assert_equal 'refused', row.result_status
  end
end

describe 'the MCP write kill switch' do
  include Rack::Test::Methods

  it 'refuses writes while leaving reads working' do
    ENV['MCP_WRITES_ENABLED'] = 'false'
    @app = app_with(AuditProbeTool, ScopeProbeTool)
    call_tool('audit_probe', raw: mint(scopes: ['write']).raw, arguments: { note: 'x' })
    assert tool_result['isError']
    call_tool('scope_probe', raw: mint(scopes: ['read']).raw)
    refute tool_result['isError']
  ensure
    ENV.delete('MCP_WRITES_ENABLED')
  end
end

describe 'MCP audit logging' do
  include Rack::Test::Methods

  before { @app = app_with(AuditProbeTool) }

  it 'lands a row when a write succeeds' do
    token = mint(scopes: ['write'])
    call_tool('audit_probe', raw: token.raw, arguments: { note: 'done' })
    row = Tectonic::McpAuditLog.where(oauth_application_id: token.application_id).first
    assert_equal 'success', row.result_status
  end

  it 'lands a row when a write fails' do
    token = mint(scopes: ['write'])
    call_tool('audit_probe', raw: token.raw, arguments: { note: 'boom' })
    row = Tectonic::McpAuditLog.where(oauth_application_id: token.application_id).first
    assert_equal 'error', row.result_status
  end
end

describe 'MCP schema validation' do
  include Rack::Test::Methods

  before { @app = app_with(AuditProbeTool) }

  it 'rejects malformed arguments with a usable error' do
    raw = mint(scopes: ['write']).raw
    call_tool('audit_probe', raw:, arguments: { note: 123 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text').downcase, 'invalid'
  end
end

