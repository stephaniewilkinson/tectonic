# frozen_string_literal: true

require 'base64'
require 'openssl'
require 'securerandom'
require 'roda'

class Tectonic < Roda
  module OAuth
    # Names the grant a refresh token was issued for, inside the token itself. The
    # token reads "<grant id>~<secret>~<mac>", where the mac is an HMAC over the first
    # two parts under a key derived from the session secret. The id is what lets a
    # replayed token be traced back to the grant it came from once rotation has thrown
    # the old hash away; the mac is what stops anyone from making that up, since a
    # forged "12~x~y" would otherwise revoke grant 12 for whoever holds it.
    module RefreshTokenTag
      SEPARATOR = '~'
      # HMAC key separation: this key signs refresh-token tags and nothing else, so a
      # tag can never be confused with any other thing the session secret protects.
      PURPOSE = 'oauth refresh token grant tag'

      module_function

      # A refresh token that names `grant_id`.
      def issue(grant_id)
        body = "#{grant_id}#{SEPARATOR}#{SecureRandom.urlsafe_base64(32)}"
        "#{body}#{SEPARATOR}#{mac(body)}"
      end

      # The grant a token names, or nil for anything this server did not issue: a
      # malformed token, a forged tag, or a token minted before tagging existed.
      def grant_id(token)
        id, secret, tag = token.to_s.split(SEPARATOR)
        return unless id && secret && tag && !id.empty?
        return unless OpenSSL.secure_compare(mac("#{id}#{SEPARATOR}#{secret}"), tag)

        id.to_i
      end

      def mac(body)
        Base64.urlsafe_encode64(OpenSSL::HMAC.digest('SHA256', key, body), padding: false)
      end

      def key
        @key ||= OpenSSL::HMAC.digest('SHA256', SESSION_SECRET, PURPOSE)
      end
    end

    # Revokes the grant behind a replayed refresh token, which rodauth-oauth's rotation
    # policy detects but does not act on. Rotation replaces the refresh-token hash on
    # the single grant row, so a replayed token matches no row at all: the library can
    # only answer invalid_grant, and the grant stays live -- meaning whoever rotated
    # first, thief or legitimate client, keeps the account. RFC 9700 section 4.14.2
    # requires the grant to die on detected reuse, because that is the only outcome
    # that costs an attacker anything. The tag each token carries names its grant, so
    # the row can still be found after its hash is gone. Prepended into the Rodauth
    # auth class so these sit in front of the feature methods they extend.
    module RefreshTokenReuse
      private

      # The refresh grant. The lookup is the same locking read the library does one
      # line later, so two clients racing the same token serialize here: the loser
      # re-reads after the winner commits, finds nothing, and revokes.
      def create_token(grant_type)
        return super unless grant_type == 'refresh_token' && (presented = param_or_nil('refresh_token'))

        grant = oauth_grant_by_refresh_token_ds(presented, revoked: true).for_update.first
        revoke_replayed_grant(presented) unless grant
        @tagged_grant_id = grant && grant[oauth_grants_id_column]
        super
      end

      # Kills the grant a replayed token was issued for, leaving the library to refuse
      # the request as it already does. A token with no usable tag -- forged, or issued
      # before this existed -- names no grant and revokes nothing; the client that
      # holds an untagged token gets a tagged one from its next rotation.
      def revoke_replayed_grant(token)
        grant_id = RefreshTokenTag.grant_id(token)
        return unless grant_id

        db[oauth_grants_table]
          .where(oauth_grants_id_column => grant_id,
                 oauth_grants_oauth_application_id_column => oauth_application[oauth_applications_id_column],
                 oauth_grants_revoked_at_column => nil)
          .update(oauth_grants_revoked_at_column => Sequel::CURRENT_TIMESTAMP)
      end

      # The grant row a token is about to be issued against, which is what the tag has
      # to name. The authorization-code exchange arrives here with the grant row it
      # locked; the rotation above sets it from the row the presented token matched.
      def generate_token(grant_params = {}, *)
        @tagged_grant_id = grant_params[oauth_grants_id_column]
        super
      end

      # Same contract as the library's: mint the token, leave its hash in `params`,
      # return the token. Falls back to the untagged original when there is no grant to
      # name, which is the client-credentials path, where no refresh token is issued.
      def _generate_refresh_token(params)
        return super unless @tagged_grant_id && oauth_grants_refresh_token_hash_column

        token = RefreshTokenTag.issue(@tagged_grant_id)
        params[oauth_grants_refresh_token_hash_column] = generate_token_hash(token)
        token
      end
    end
  end
end

