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
      # Every client here is public, so 'none' is the only auth method advertised --
      # naming client_secret_post as well would promise a client authentication the token
      # endpoint does not perform, which reads as a stronger guarantee than it is.
      def authorization_server
        endpoints(MCP::Config.public_base_url).merge(capabilities)
      end

      # Where each part of the flow lives, all derived from the one public origin.
      def endpoints(base)
        {
          issuer: base, authorization_endpoint: "#{base}/authorize",
          token_endpoint: "#{base}/token", registration_endpoint: "#{base}/register",
          revocation_endpoint: "#{base}/revoke"
        }
      end

      # What this server will actually do, which is deliberately the smaller list.
      def capabilities
        {
          scopes_supported: SCOPES, response_types_supported: ['code'],
          grant_types_supported: %w[authorization_code refresh_token],
          code_challenge_methods_supported: ['S256'],
          token_endpoint_auth_methods_supported: ['none'],
          revocation_endpoint_auth_methods_supported: ['none']
        }
      end
    end
  end
end

