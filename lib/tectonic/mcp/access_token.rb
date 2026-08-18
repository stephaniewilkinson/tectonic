# frozen_string_literal: true

require 'jwt'
require_relative 'config'
require_relative '../oauth_keys'

class Tectonic < Roda
  module MCP
    # Verifies an OAuth JWT access token the way a resource server must: the signature
    # against the authorization server's public key, the expiry, and -- per RFC 8707 --
    # that this MCP endpoint is the token's intended audience. Because the authorization
    # server and this resource server run in one process, the verify is local: no
    # introspection round-trip and no coupling to rodauth-oauth's grant table. Returns
    # the claims on success and nil on any failure, so a bad token is simply
    # unauthenticated.
    module AccessToken
      module_function

      def verify(raw)
        return if raw.nil? || raw.empty?

        claims, = JWT.decode(raw, OAuthKeys.public_key, true,
                             algorithm: OAuthKeys::ALGORITHM, verify_aud: true, aud: Config.resource_url)
        claims
      rescue JWT::DecodeError
        nil
      end
    end
  end
end

