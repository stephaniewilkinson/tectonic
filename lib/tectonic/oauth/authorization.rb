# frozen_string_literal: true

require 'rack/utils'
require_relative '../oauth_client'
require_relative 'authorize_request'

class Tectonic < Roda
  module OAuth
    # Validates a /authorize request before any login prompt or consent screen. The order
    # is deliberate: the client and redirect_uri are checked first, and a failure there is
    # a page error that never redirects (an unvalidated redirect_uri is an open redirector
    # waiting to happen). Only once those are trusted do other protocol errors redirect
    # back to the client with an RFC 6749 error code.
    module Authorization
      module_function

      SUPPORTED_SCOPES = %w[read write offline_access].freeze

      # A validation outcome. Exactly one of three shapes: a page error (bad client or
      # redirect_uri), a redirect error (valid target, bad protocol params), or an ok
      # request the caller proceeds with.
      Result = Struct.new(:request, :error, :redirect_uri, :state, keyword_init: true) do
        def client_error?
          request.nil? && redirect_uri.nil?
        end

        def redirect_error?
          request.nil? && !redirect_uri.nil?
        end

        # Where a redirect error sends the browser: back to the client with error+state.
        def redirect_error_url
          query = { error: error.to_s }
          query[:state] = state unless state.to_s.empty?
          "#{redirect_uri}?#{Rack::Utils.build_query(query)}"
        end
      end

      def validate(params)
        client = OAuthClient.locate(params['client_id'])
        return page_error unless client&.redirect_uri_allowed?(params['redirect_uri'])

        code = protocol_error(params)
        return redirect_error(params, code) if code

        Result.new(request: build_request(client, params))
      end

      # The first failing protocol check as an RFC 6749 error code, or nil when all pass.
      # PKCE is mandatory and S256-only: a missing challenge or the plain method is refused.
      def protocol_error(params)
        return 'unsupported_response_type' unless params['response_type'] == 'code'
        return 'invalid_request' if params['code_challenge'].to_s.empty?
        return 'invalid_request' unless params['code_challenge_method'] == 'S256'
        return 'invalid_scope' unless scopes_supported?(params['scope'])

        nil
      end

      def scopes_supported?(scope)
        scope.to_s.split.all? { |name| SUPPORTED_SCOPES.include?(name) }
      end

      def build_request(client, params)
        AuthorizeRequest.new(
          client:, client_id: client.client_id, redirect_uri: params['redirect_uri'],
          scopes: granted_scopes(params['scope'], client), code_challenge: params['code_challenge'],
          code_challenge_method: params['code_challenge_method'], resource: params['resource'],
          state: params['state']
        )
      end

      # The scopes the code will carry: those requested, narrowed to what this server
      # supports; falling back to the client's registered scopes, then to read-only.
      def granted_scopes(scope, client)
        requested = scope.to_s.split
        requested = client.scope_list if requested.empty?
        requested = ['read'] if requested.empty?
        requested & SUPPORTED_SCOPES
      end

      def page_error
        Result.new
      end

      def redirect_error(params, code)
        Result.new(error: code, redirect_uri: params['redirect_uri'], state: params['state'])
      end
    end
  end
end

