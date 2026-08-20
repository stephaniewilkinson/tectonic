# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/oauth/redirect_uri'

# Reads better than the whole constant on every line.
module RedirectPolicy
  def allowed?(uri)
    Tectonic::OAuth::RedirectUri.allowed?(uri)
  end
end

describe Tectonic::OAuth::RedirectUri do
  include RedirectPolicy

  it 'admits the published Claude and ChatGPT callbacks' do
    assert allowed?('https://claude.ai/api/mcp/auth_callback')
    assert allowed?('https://claude.com/api/mcp/auth_callback')
    assert allowed?('https://chatgpt.com/connector_platform_oauth_redirect')
    assert allowed?('https://chatgpt.com/connector/oauth/f8a1c2')
  end

  it 'refuses a callback pointing anywhere else' do
    refute allowed?('https://evil.example/steal')
    refute allowed?('https://claude.ai.evil.example/api/mcp/auth_callback')
    refute allowed?('https://evil.example/api/mcp/auth_callback')
  end
end

# Only the port may vary on loopback, because a native client binds an ephemeral one
# it cannot know at registration time. A host that merely reads like loopback is the
# whole attack, so nothing else about the URI is forgiven.
describe 'Tectonic::OAuth::RedirectUri on loopback' do
  include RedirectPolicy

  it 'admits any port' do
    assert allowed?('http://127.0.0.1:53791/callback')
    assert allowed?('http://localhost:9292/oauth/callback')
    assert allowed?('http://[::1]:8080/callback')
  end

  it 'refuses a lookalike host and a scheme that is not http' do
    refute allowed?('http://localhost.evil.example:9292/callback')
    refute allowed?('http://127.0.0.1.evil.example/callback')
    refute allowed?('https://127.0.0.1:53791/callback')
  end
end

describe 'Tectonic::OAuth::RedirectUri on an exact entry' do
  include RedirectPolicy

  it 'refuses a claimed callback with anything appended to it' do
    refute allowed?('https://claude.ai/api/mcp/auth_callback/../../evil')
    refute allowed?('https://claude.ai/api/mcp/auth_callback?next=https://evil.example')
    refute allowed?('https://claude.ai:8443/api/mcp/auth_callback')
    refute allowed?('https://chatgpt.com/connector/oauth')
  end

  it 'refuses what is not a callback at all' do
    refute allowed?(nil)
    refute allowed?('')
    refute allowed?('not a uri')
    refute allowed?('/api/mcp/auth_callback')
    refute allowed?('javascript:alert(1)')
  end
end

# The list is configuration so a new client can be admitted without a deploy, which
# also means the defaults are gone the moment it is set.
describe 'Tectonic::OAuth::RedirectUri configured from the environment' do
  include RedirectPolicy

  it 'replaces the defaults with OAUTH_REDIRECT_URI_ALLOWLIST' do
    ENV['OAUTH_REDIRECT_URI_ALLOWLIST'] = 'https://mcp.example/cb, https://other.example/cb'

    assert allowed?('https://mcp.example/cb')
    assert allowed?('https://other.example/cb')
    refute allowed?('https://claude.ai/api/mcp/auth_callback')
  ensure
    ENV.delete('OAUTH_REDIRECT_URI_ALLOWLIST')
  end
end

