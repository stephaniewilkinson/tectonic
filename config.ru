# frozen_string_literal: true

require 'rack/timeout/base'
require_relative 'app'
require_relative 'lib/tectonic/mcp'

# rack-timeout's observer logs a line on every state change, and two of those -- ready
# and completed -- happen on every request that ever finishes. This app logs no requests
# at all otherwise, so leaving that at its info default would make rack-timeout the
# loudest thing in the deploy log while saying nothing. ERROR keeps the two states worth
# reading: a request that ran past its timeout, and one dropped before it ran.
Rack::Timeout::Logger.level = Logger::ERROR

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

# How long a request may hold a thread before rack-timeout raises inside it. Without one
# a request that blocks -- a slow query, a lock, a wait on the connection pool -- holds
# its thread for as long as it takes, and with five Puma threads against a pool of four
# (#150) it does not take many of those before the instance answers nothing and the
# symptom reads as "the site is down" rather than as one slow query. Twenty seconds is far
# above anything here honestly takes: Volume.weekly and Volume.top_sets aggregate an
# account's whole history and ProgramGenerator writes a week of workouts inside one
# transaction, and none of them is within an order of magnitude of it. It is also far
# below forever, which is the only other setting on offer today.
#
# It is not free. rack-timeout interrupts with Thread#raise, so the error lands wherever
# the thread happened to be, including in the middle of a query, and unwinding from there
# is less orderly than raising somewhere the code expected to be raised at. That is the
# price of interrupting at all, and the alternative on offer is not interrupting.
#
# The variable is rack-timeout's own, so the number moves without editing this file, and
# 0 switches the timeout off, which is what a local run sitting in a debugger wants.
service_timeout = ENV.fetch('RACK_TIMEOUT_SERVICE_TIMEOUT', 20).to_i

# The MCP endpoint is mounted alongside the Roda app but entirely outside it: its own
# bearer-token auth and the plain-Rack transport never touch Roda's sessions, CSRF, or
# assets. URLMap routes by path prefix -- the endpoint path to the MCP stack,
# everything else to Roda.
#
# The timeout wraps the Roda leg only, rather than going on with `use` above where it
# would cover both. The MCP transport serves subscriptions/listen as an SSE stream held
# open for as long as the client wants it, with a keepalive every fifteen seconds, so any
# finite service timeout would sever every one of those on schedule; that leg's backstop
# is the Puma worker_timeout in #150, which is the other half of this. OAuth is inside
# Roda and does take the timeout -- a bcrypt compare and an RSA signature are the whole of
# what it does, and neither is slow enough to want an exemption it would then hide behind.
#
# Sentry, when it is on, is used above and so wraps this: the error rack-timeout raises
# propagates up through it and arrives as a report with a backtrace pointing at whatever
# was still running. That is the point of raising rather than just dropping the request.
run Rack::URLMap.new(
  Tectonic::MCP::Config.endpoint_path => Tectonic::MCP.rack_app,
  '/' => Rack::Timeout.new(Tectonic.freeze.app, service_timeout:)
)

