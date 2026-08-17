# frozen_string_literal: true

require 'mcp'
require_relative 'mcp/config'
require_relative 'mcp/logging'
require_relative 'mcp/request_context'
require_relative 'mcp/tool'
require_relative 'mcp/tools/whoami'
require_relative 'mcp/server'
require_relative 'mcp/auth'

class Tectonic < Roda
  # The MCP endpoint, assembled here and mounted in config.ru. Everything under this
  # namespace is deliberately outside Roda's session/CSRF/asset stack: the transport
  # is a plain Rack app, and Auth is a plain Rack middleware in front of it.
  module MCP
    class << self
      # The Rack app to mount at Config.endpoint_path. Auth wraps a dispatcher that
      # builds a fresh stateless server and transport per request, each scoped to the
      # account the token resolved to. Stateless mode keeps no session state and starts
      # no threads, so per-request construction is cheap and safe.
      def rack_app
        Auth.new(method(:dispatch))
      end

      # Serves one already-authenticated request: builds the per-account server and its
      # transport, then hands off. Reached only after Auth resolved the account.
      def dispatch(env)
        transport(env.fetch(Auth::CONTEXT_KEY)).call(env)
      end

      # A stateless Streamable HTTP transport for one account context. DNS-rebinding
      # protection stays on (the gem's default); the allow lists widen it for the
      # deployed host/origin, read from config.
      def transport(context)
        ::MCP::Server::Transports::StreamableHTTPTransport.new(
          ServerFactory.build(context),
          stateless: true,
          allowed_hosts: Config.allowed_hosts,
          allowed_origins: Config.allowed_origins
        )
      end
    end
  end
end

