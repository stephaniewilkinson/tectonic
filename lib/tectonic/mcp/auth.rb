# frozen_string_literal: true

require 'json'
require_relative '../api_token'
require_relative 'config'
require_relative 'request_context'

class Tectonic < Roda
  module MCP
    # Rack middleware that authenticates the bearer token before the request reaches
    # the transport. A missing, malformed, unknown, expired, or revoked token is
    # rejected with 401 here, so the MCP server only ever runs for a resolved account.
    # On success it touches last_used_at, builds the account context, and stashes it in
    # env for the app it wraps.
    class Auth
      # env key the downstream app reads the resolved context from.
      CONTEXT_KEY = 'tectonic.mcp_context'
      # `Bearer` then one run of whitespace then a non-empty, whitespace-free token.
      BEARER = /\ABearer[[:space:]]+(?<token>\S+)\z/

      def initialize(app)
        @app = app
      end

      def call(env)
        token = token_for(env)
        return unauthorized('Missing or invalid bearer token.') unless token

        token.touch_last_used!
        env[CONTEXT_KEY] = RequestContext.from_token(token)
        @app.call(env)
      end

      private

      # The live ApiToken for the request's bearer credential, or nil when the header is
      # absent or malformed, the token is unknown/expired/revoked, or (for an OAuth token)
      # its audience is not this endpoint.
      def token_for(env)
        match = BEARER.match(env['HTTP_AUTHORIZATION'].to_s)
        token = match && ApiToken.verify(match[:token])
        token if token && correct_audience?(token)
      end

      # Audience binding (RFC 8707): an OAuth token is only honored at the resource it was
      # issued for, so a token minted for another server cannot be replayed here. Personal
      # access tokens carry no audience and are unaffected.
      def correct_audience?(token)
        return true unless token.oauth?

        token.resource == Config.resource_url
      end

      def unauthorized(message)
        body = { jsonrpc: '2.0', id: nil, error: { code: -32_001, message: message } }
        [401, response_headers, [body.to_json]]
      end

      # Point unauthenticated clients at the protected-resource metadata (RFC 9728) so
      # claude.ai can discover the authorization server and start the OAuth flow.
      def response_headers
        metadata = "#{Config.public_base_url}/.well-known/oauth-protected-resource"
        { 'content-type' => 'application/json',
          'www-authenticate' => "Bearer resource_metadata=\"#{metadata}\"" }
      end
    end
  end
end

