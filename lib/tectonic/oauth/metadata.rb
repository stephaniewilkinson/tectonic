# frozen_string_literal: true

require_relative '../mcp/config'

class Tectonic < Roda
  module OAuth
    # The two discovery documents claude.ai reads before it ever hits the endpoint:
    # RFC 9728 (protected resource) points at the authorization server, and RFC 8414
    # (authorization server) describes exactly what this server supports. Both are built
    # from MCP::Config.public_base_url so a single env var relocates the whole surface.
    module Metadata
      module_function

      SCOPES = %w[read write offline_access].freeze

      # RFC 9728: tells a client which authorization server protects /mcp and how.
      def protected_resource
        {
          resource: MCP::Config.resource_url,
          authorization_servers: [MCP::Config.public_base_url],
          scopes_supported: SCOPES,
          bearer_methods_supported: ['header']
        }
      end

      # RFC 8414: the authorization server's own capabilities. S256-only PKCE and the
      # authorization_code + refresh_token grants are the whole of what we implement.
      def authorization_server
        base = MCP::Config.public_base_url
        {
          issuer: base, authorization_endpoint: "#{base}/authorize",
          token_endpoint: "#{base}/token", registration_endpoint: "#{base}/register",
          scopes_supported: SCOPES, response_types_supported: ['code'],
          grant_types_supported: %w[authorization_code refresh_token],
          code_challenge_methods_supported: ['S256'],
          token_endpoint_auth_methods_supported: %w[none client_secret_post]
        }
      end
    end
  end
end

