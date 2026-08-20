# frozen_string_literal: true

require 'jwt'
require_relative 'config'
require_relative '../db'
require_relative '../oauth_keys'

class Tectonic < Roda
  module MCP
    # Verifies an OAuth JWT access token the way a resource server must: the signature
    # against the authorization server's public key, the expiry, that this MCP endpoint
    # is the token's intended audience (RFC 8707), and that the grant behind it has not
    # been revoked. Returns the claims on success and nil on any failure, so a bad token
    # is simply unauthenticated.
    #
    # The first three checks are local and free. The fourth costs one primary-key lookup,
    # which is the price of a revocable token: a JWT is otherwise valid on its signature
    # alone, so revoking a grant would stop new tokens while every token already issued
    # kept working for its full hour. That is the window a stolen token lives in, so the
    # lookup is worth it. It is still not an introspection round-trip -- the authorization
    # server shares this process and this database.
    module AccessToken
      module_function

      def verify(raw)
        return if raw.nil? || raw.empty?

        claims, = JWT.decode(raw, OAuthKeys.public_key, true,
                             algorithm: OAuthKeys::ALGORITHM, verify_aud: true, aud: Config.resource_url)
        claims if live_grant?(claims)
      rescue JWT::DecodeError
        nil
      end

      # Whether the grant this token names is still live. A token naming no grant is
      # refused: every token this server issues carries `gid` (see OAuth::GrantBoundTokens),
      # so an absent one is either forged or predates the claim, and treating it as valid
      # is precisely the hole this closes. Access tokens last an hour, so the worst a
      # client sees across a deploy is one refresh.
      def live_grant?(claims)
        id = claims['gid']
        return false unless id

        !DB[:oauth_grants].where(id: id, revoked_at: nil).empty?
      end
    end
  end
end

