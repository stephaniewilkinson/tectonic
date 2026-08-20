# frozen_string_literal: true

require 'json'
require_relative 'access_token'
require_relative 'config'
require_relative 'request_context'

class Tectonic < Roda
  module MCP
    # Rack middleware that authenticates the OAuth bearer token before the request
    # reaches the transport. This is the resource-server half of "all auth on rodauth":
    # a missing, malformed, expired, wrong-audience, or badly signed JWT is rejected
    # here with a 401 that points the client (per RFC 9728) at the protected-resource
    # metadata, so the MCP server only ever runs for a resolved account. On success it
    # builds the account context from the token's claims and stashes it in env.
    class Auth
      # env key the downstream app reads the resolved context from.
      CONTEXT_KEY = 'tectonic.mcp_context'
      # `Bearer` then one run of whitespace then a non-empty, whitespace-free token.
      BEARER = /\ABearer[[:space:]]+(?<token>\S+)\z/

      def initialize(app)
        @app = app
      end

      def call(env)
        claims = claims_for(env)
        return unauthorized('Missing or invalid bearer token.') unless claims

        env[CONTEXT_KEY] = RequestContext.from_claims(claims)
        @app.call(env)
      end

      private

      # The verified JWT claims for the request's bearer credential, or nil when the
      # header is absent or malformed or the token fails verification.
      def claims_for(env)
        match = BEARER.match(env['HTTP_AUTHORIZATION'].to_s)
        match && AccessToken.verify(match[:token])
      end

      def unauthorized(message)
        body = { jsonrpc: '2.0', id: nil, error: { code: -32_001, message: message } }
        [401, response_headers, [body.to_json]]
      end

      # RFC 9728 / RFC 6750: name the protected-resource metadata and the scopes a
      # client needs, so an MCP client can discover the authorization server and ask
      # for the right grant.
      def response_headers
        challenge = 'Bearer realm="tectonic-mcp"' \
                    ", resource_metadata=\"#{Config.resource_metadata_url}\"" \
                    ", scope=\"#{Config.scopes.join(' ')}\""
        { 'content-type' => 'application/json', 'www-authenticate' => challenge }
      end
    end
  end
end

