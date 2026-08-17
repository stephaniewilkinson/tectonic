# frozen_string_literal: true

require 'securerandom'
require_relative 'db'
require_relative 'oauth/redirect_uri'

class Tectonic < Roda
  # A registered OAuth client (RFC 7591). claude.ai and other public clients hold no
  # secret and register with token_endpoint_auth_method 'none'; redirect_uris is the
  # exact allow-list the authorize endpoint checks an incoming redirect_uri against.
  class OAuthClient < Sequel::Model(:oauth_clients)
    # Registers a public client, generating an unguessable client_id and storing the
    # already-validated URI/grant/response/scope lists as Postgres text[] arrays.
    def self.register(client_name:, redirect_uris:, grant_types:, response_types:, scopes:)
      create(
        client_id: SecureRandom.urlsafe_base64(24), client_name:,
        redirect_uris: pg(redirect_uris), grant_types: pg(grant_types),
        response_types: pg(response_types), token_endpoint_auth_method: 'none',
        scopes: pg(scopes)
      )
    end

    # The client for a client_id, or nil. Never raises on a missing/blank id.
    def self.locate(client_id)
      client_id && where(client_id:).first
    end

    # Wraps a Ruby array as a Postgres text[] literal, the storage shape for every list.
    def self.pg(list)
      Sequel.pg_array(Array(list).map(&:to_s), :text)
    end

    # Whether `candidate` matches one of the registered redirect_uris (loopback
    # port-agnostic, everything else exact). This is the anti-open-redirect gate.
    def redirect_uri_allowed?(candidate)
      redirect_uri_list.any? { |registered| OAuth::RedirectUri.match?(registered, candidate) }
    end

    def redirect_uri_list
      Array(redirect_uris).map(&:to_s)
    end

    def scope_list
      Array(scopes).map(&:to_s)
    end

    # Only loopback callbacks are registered: the consent screen warns the user, because
    # any local process can bind a loopback port and intercept the returned code.
    def loopback_only?
      list = redirect_uri_list
      list.any? && list.all? { |uri| OAuth::RedirectUri.loopback?(uri) }
    end
  end
end

