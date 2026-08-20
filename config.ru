# frozen_string_literal: true

require_relative 'app'
require_relative 'lib/tectonic/mcp'

# Error reporting, in the two environments that have somewhere to report to. This was
# Rollbar, configured from an access token written into this file, in a public
# repository, where it sat readable for three years. Sentry replaces it and the DSN comes
# from the environment, so nothing here is a credential any more and there is no longer a
# secret in the source to rotate.
#
# A DSN that is missing switches reporting off rather than refusing the boot, and missing
# means both ways a variable can be: unset, or set to the empty string by a file that
# lists the name. That is deliberately unlike OAuthKeys, which raises without
# OAUTH_JWT_PRIVATE_KEY. An app that cannot sign access tokens is broken in a way that
# hides itself -- it mints an ephemeral key and every token already issued quietly stops
# verifying -- whereas an app that cannot report its errors serves every request exactly
# as before. Refusing to boot over a missing monitoring credential would turn it into an
# outage, a worse failure than the ones it would have been reporting and one that lands
# mid-deploy, so the absence is said once on stderr where the deploy log keeps it.
case ENV.fetch('RACK_ENV', nil)
when 'production', 'staging'
  require 'sentry-ruby'
  dsn = ENV.fetch('SENTRY_DSN', nil).to_s
  if dsn.empty?
    warn 'SENTRY_DSN is not set: error reporting is off for this boot.'
  else
    Sentry.init do |config|
      config.dsn = dsn
      # Production and staging report to the same project and have to be told apart
      # there. send_default_pii stays off, its default: turning it on would ship request
      # headers and IP addresses of people's training logs to a third party, which is a
      # decision for whoever owns the Sentry project rather than a line in a config file.
      config.environment = ENV.fetch('RACK_ENV')
    end
    # Sentry hooks itself into Rails automatically and into a plain Rack app not at all,
    # so the middleware is inserted by hand. It goes on before `run` and therefore wraps
    # the whole URLMap, which is what puts the MCP endpoint inside it as well as Roda.
    use Sentry::Rack::CaptureExceptions
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

