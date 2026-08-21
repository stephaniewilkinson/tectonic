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

      # Deliberately a bare string rather than a rendered template: this middleware runs
      # in front of the MCP transport, outside the Roda app entirely, and reaching back
      # into the view layer for one static page would couple the two for nothing.
      SIGNPOST_HTML = <<~HTML
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <title>tectonic plates &mdash; MCP endpoint</title>
        <meta name="robots" content="noindex, nofollow">
        <style>
          body { font: 16px/1.6 system-ui, sans-serif; margin: 4rem auto; max-width: 34rem; padding: 0 1.5rem; color: #1f2937; }
          code { background: #f3f4f6; border-radius: 4px; padding: .15rem .35rem; font-size: .9em; }
          a { color: #4d7c0f; }
        </style></head>
        <body>
          <h1>This is the MCP endpoint</h1>
          <p>It is where an AI assistant talks to tectonic plates, not a page to visit.
             There is nothing to see here in a browser.</p>
          <p>To connect an assistant, go to <a href="/connections">assistants</a> and give
             it the address shown there.</p>
        </body></html>
      HTML

      def initialize(app)
        @app = app
      end

      def call(env)
        claims = claims_for(env)
        return signpost if claims.nil? && browsing?(env)
        return unauthorized('Missing or invalid bearer token.') unless claims

        env[CONTEXT_KEY] = RequestContext.from_claims(claims)
        @app.call(env)
      end

      private

      # Somebody who typed this address into a browser rather than a client speaking the
      # protocol: a GET, asking for HTML, carrying no credential. An MCP client sends
      # POST and asks for JSON or an event stream, so it never matches.
      def browsing?(env)
        env['REQUEST_METHOD'] == 'GET' &&
          env['HTTP_ACCEPT'].to_s.include?('text/html') &&
          env['HTTP_AUTHORIZATION'].to_s.empty?
      end

      # The same 401 a client gets, with a page instead of a JSON-RPC error. This address
      # is an endpoint for an assistant to talk to, not a page to visit, and a wall of
      # JSON says that to nobody. The status and the challenge header are unchanged, so
      # anything speaking the protocol is unaffected by what a browser is shown.
      def signpost
        [401, response_headers.merge('content-type' => 'text/html; charset=utf-8'), [SIGNPOST_HTML]]
      end

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

