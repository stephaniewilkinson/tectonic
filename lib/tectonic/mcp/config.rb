# frozen_string_literal: true

require_relative '../db'

class Tectonic < Roda
  module MCP
    # Every operational knob for the MCP endpoint, read from the environment rather
    # than hardcoded: the mount path, the write kill switch, the DNS-rebinding allow
    # lists, and whether reads are audited. Nothing here holds request state, so it is
    # safe to read per request.
    module Config
      # Values that read as "off" for a boolean env var; anything else (including unset
      # handled by the caller's default) is on.
      FALSEY = %w[false 0 no off].freeze

      module_function

      # Where the transport is mounted. The auth middleware and docs read this so the
      # path lives in one place.
      def endpoint_path
        ENV.fetch('MCP_ENDPOINT_PATH', '/mcp')
      end

      # The externally reachable origin of this deployment, e.g. https://tectonicplates.app
      # in production. Every OAuth issuer/metadata URL and the token audience derive from
      # it, so a misconfigured base URL fails closed rather than pointing at localhost.
      def public_base_url
        ENV.fetch('MCP_PUBLIC_BASE_URL', 'http://localhost:9292')
      end

      # The protected resource identifier and OAuth token audience: the public origin plus
      # the endpoint path. An OAuth token whose `resource` is not exactly this is refused.
      def resource_url
        "#{public_base_url}#{endpoint_path}"
      end

      # The global write kill switch (spec §5). Default on; flip MCP_WRITES_ENABLED to
      # a falsey value to make every write tool refuse while reads keep working.
      def writes_enabled?
        on?('MCP_WRITES_ENABLED', default: true)
      end

      # Whether successful/failed reads land an audit row. Writes are always audited;
      # reads default off to keep the log signal-heavy.
      def audit_reads?
        on?('MCP_AUDIT_READS', default: false)
      end

      # Scopes the server recognizes. Tokens are minted against these and tools declare
      # one of them.
      def scopes
        list('MCP_SCOPES', default: %w[read write])
      end

      # Extra Host header values the transport accepts beyond the loopback defaults
      # (127.0.0.1, ::1, localhost). A non-loopback deployment lists its public host here.
      def allowed_hosts
        list('MCP_ALLOWED_HOSTS', default: [])
      end

      # Extra Origin header values accepted for browser clients, beyond same-origin.
      def allowed_origins
        list('MCP_ALLOWED_ORIGINS', default: [])
      end

      def server_name
        ENV.fetch('MCP_SERVER_NAME', 'Tectonic')
      end

      def server_version
        ENV.fetch('MCP_SERVER_VERSION', '1.0.0')
      end

      # High-level orientation for a model, per spec §6: what Tectonic is and the one
      # unit fact that trips up every numeric tool. Tool-specific guidance stays on tools.
      def instructions
        'Tectonic is a barbell strength-training tracker: accounts log workouts, each ' \
          'containing sets of an exercise with a weight and rep count. All weights are ' \
          'integer pounds. Every tool acts only on the authenticated account.'
      end

      def on?(key, default:)
        value = ENV.fetch(key, nil)
        return default if value.nil? || value.empty?

        !FALSEY.include?(value.downcase)
      end

      def list(key, default:)
        value = ENV.fetch(key, nil)
        return default if value.nil? || value.empty?

        value.split(/[\s,]+/).reject(&:empty?)
      end
    end
  end
end

