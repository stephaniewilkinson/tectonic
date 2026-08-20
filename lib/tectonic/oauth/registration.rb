# frozen_string_literal: true

require_relative '../oauth_client'
require_relative 'redirect_uri'

class Tectonic < Roda
  module OAuth
    # Dynamic client registration (RFC 7591). claude.ai POSTs its callback URIs and gets
    # back a public client_id with no secret. Registration is the first gate on redirect
    # URIs: only the claude.ai callback and loopback URIs may be stored, so the authorize
    # endpoint can never be handed a client whose redirect set points somewhere hostile.
    #
    # The endpoint is unauthenticated by design, which makes every bound here load-bearing:
    # each field a caller controls is checked for type and size before it reaches a column,
    # so an anonymous caller cannot choose how much storage one request consumes.
    module Registration
      module_function

      GRANTS = %w[authorization_code refresh_token].freeze
      RESPONSES = %w[code].freeze
      SCOPES = %w[read write offline_access].freeze
      MAX_REDIRECT_URIS = 10
      MAX_NAME_LENGTH = 200

      # Registers from a parsed JSON body. Returns [status, body_hash]: 201 + client
      # metadata on success, 400 + an RFC 7591 error otherwise.
      def call(body)
        uris = Array(body['redirect_uris']).grep(String)
        reason = rejection(body, uris)
        return invalid(reason) if reason

        [201, metadata(create(body, uris))]
      end

      # The first reason to refuse a registration, or nil to proceed.
      def rejection(body, uris)
        return 'redirect_uris is required' if uris.empty?
        return "at most #{MAX_REDIRECT_URIS} redirect_uris" if uris.length > MAX_REDIRECT_URIS
        return 'a redirect_uri is not permitted' unless uris.all? { |uri| RedirectUri.acceptable?(uri) }
        return "client_name is at most #{MAX_NAME_LENGTH} characters" unless name_ok?(body['client_name'])

        nil
      end

      # A client_name is optional, but when given it has to be a string of bounded length:
      # anything else is either unbounded storage or a value Sequel would hand to Postgres
      # as an expression rather than a literal.
      def name_ok?(name)
        name.nil? || (name.is_a?(String) && name.length <= MAX_NAME_LENGTH)
      end

      def create(body, uris)
        OAuthClient.register(
          client_name: body['client_name'], redirect_uris: uris,
          grant_types: pick(body['grant_types'], GRANTS),
          response_types: pick(body['response_types'], RESPONSES),
          scopes: pick(scope_list(body['scope']), SCOPES)
        )
      end

      # The requested scope string, or nothing when it is not a string at all.
      def scope_list(scope)
        scope.is_a?(String) ? scope.split : []
      end

      # A requested list narrowed to the supported set, defaulting to the whole set when
      # the client asked for nothing (or nothing we recognize).
      def pick(requested, supported)
        chosen = Array(requested).grep(String) & supported
        chosen.empty? ? supported : chosen
      end

      # The RFC 7591 registration response for a stored client.
      def metadata(client)
        {
          client_id: client.client_id, client_id_issued_at: client.created_at.to_i,
          client_name: client.client_name, redirect_uris: client.redirect_uri_list,
          grant_types: client.grant_types.to_a, response_types: client.response_types.to_a,
          token_endpoint_auth_method: client.token_endpoint_auth_method,
          scope: client.scope_list.join(' ')
        }
      end

      def invalid(description)
        [400, { error: 'invalid_client_metadata', error_description: description }]
      end
    end
  end
end

