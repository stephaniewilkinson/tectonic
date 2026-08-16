# frozen_string_literal: true

require_relative 'app'
require_relative 'lib/tectonic/mcp'

case ENV.fetch('RACK_ENV', nil)
when 'production', 'staging'
  require 'rollbar'
  Rollbar.configure do |config|
    config.access_token = 'af9bc8d8ba3046709eb245325547338b'
    config.enabled = true
  end
else
  logger = Logger.new $stdout
  logger.level = Logger::DEBUG
end

# The MCP endpoint is mounted alongside the Roda app but entirely outside it: its own
# bearer-token auth and the plain-Rack transport never touch Roda's sessions, CSRF, or
# assets. URLMap routes by path prefix -- the endpoint path to the MCP stack,
# everything else to Roda.
run Rack::URLMap.new(
  Tectonic::MCP::Config.endpoint_path => Tectonic::MCP.rack_app,
  '/' => Tectonic.freeze.app
)

