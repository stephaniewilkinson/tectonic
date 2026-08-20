# frozen_string_literal: true

require_relative '../api_token'
require_relative '../oauth_refresh_token'
require_relative 'params'

class Tectonic < Roda
  module OAuth
    # Token revocation (RFC 7009). Presenting a token is the only credential this needs:
    # the clients here are public and hold no secret, so possession is the authorisation,
    # and a caller who already holds the token gains nothing by revoking it.
    #
    # Revocation is always grant-wide. Killing a refresh token while its access token
    # still worked, or an access token while its refresh token could mint a replacement
    # seconds later, would leave the caller believing they had cut off access when they
    # had not.
    module Revocation
      module_function

      # Always 200 with an empty body: RFC 7009 section 2.2 requires an unknown token to
      # be indistinguishable from a successfully revoked one, so this endpoint cannot be
      # used to probe which tokens exist.
      def call(raw_params)
        revoke(Params.strings(raw_params)&.fetch('token', nil))
        [200, {}]
      end

      # Revokes whatever the raw value names, and everything issued alongside it.
      def revoke(raw)
        return if raw.to_s.empty?

        refresh = OAuthRefreshToken.verify(raw)
        return OAuthRefreshToken.revoke_family!(refresh.grant_id) if refresh

        access_grant(raw)
      end

      # An access token revokes its own grant when it has one, so the refresh chain dies
      # with it. Located rather than verified, because an access token that has already
      # expired can still have a live refresh token behind it.
      def access_grant(raw)
        token = ApiToken.locate(raw)
        return unless token

        chain = OAuthRefreshToken.where(access_token_id: token.id).first
        chain ? OAuthRefreshToken.revoke_family!(chain.grant_id) : token.revoke!
      end
    end
  end
end

