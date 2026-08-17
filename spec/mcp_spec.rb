# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/mcp'
require 'securerandom'

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

def mint(scopes: ['read'], account_id: nil, expires_at: nil, revoked: false)
  minted = Tectonic::ApiToken.mint(account_id: account_id || new_account, scopes:, expires_at:)
  minted.record.revoke! if revoked
  minted
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
    raw = mint(expires_at: Time.now - 60).raw
    assert_equal 401, call_tool('whoami', raw:).status
  end

  it 'rejects a revoked token' do
    raw = mint(revoked: true).raw
    assert_equal 401, call_tool('whoami', raw:).status
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
    first = mint.record.account_id
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
    row = Tectonic::McpAuditLog.where(token_id: token.record.id).first
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
    row = Tectonic::McpAuditLog.where(token_id: token.record.id).first
    assert_equal 'success', row.result_status
  end

  it 'lands a row when a write fails' do
    token = mint(scopes: ['write'])
    call_tool('audit_probe', raw: token.raw, arguments: { note: 'boom' })
    row = Tectonic::McpAuditLog.where(token_id: token.record.id).first
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

