# frozen_string_literal: true

require 'securerandom'
require 'digest'
require_relative 'db'
require_relative 'api_token'
require_relative 'oauth_client'

class Tectonic < Roda
  # A refresh token, stored as a digest and rotated on every use. Redeeming one revokes
  # it, mints a replacement, and records replaced_by_id, so presenting a rotated or
  # revoked token is an invalid_grant and a signal the token was stolen. Soft-revoked,
  # never deleted, so the rotation chain stays auditable.
  class OAuthRefreshToken < Sequel::Model(:oauth_refresh_tokens)
    Minted = Struct.new(:raw, :record)

    LIFETIME = 30 * 86_400 # seconds; a stale refresh chain ages out after ~30 days

    # Mints a refresh token bound to the access token it accompanies.
    def self.mint(account_id:, client_id:, scopes:, resource:, access_token_id:)
      raw = SecureRandom.urlsafe_base64(32)
      record = create(
        token_digest: digest(raw), account_id:, client_id:, resource:, access_token_id:,
        scopes: OAuthClient.pg(scopes), expires_at: Time.now + LIFETIME
      )
      Minted.new(raw, record)
    end

    def self.verify(raw)
      return if raw.nil? || raw.empty?

      where(token_digest: digest(raw)).first
    end

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw)
    end

    # Live until revoked (which rotation does) or expired.
    def active?
      revoked_at.nil? && (expires_at.nil? || expires_at > Time.now)
    end

    # Rotates this token: mints a fresh access token and refresh token bound to the same
    # account/client/scopes/resource, revokes self, and links replaced_by_id. Returns
    # [access, refresh] Minted pairs, or nil when the row was already rotated (reuse),
    # which the token endpoint turns into invalid_grant. The claim is atomic, so a
    # concurrent double-spend cannot mint twice.
    def rotate!
      db.transaction do
        next nil unless claim! == 1

        mint_successor
      end
    end

    # Mints the replacement access + refresh token pair bound to the same account, client,
    # scopes, and resource, and links this row to the new refresh token. Runs inside
    # rotate!'s transaction, only after the atomic claim has succeeded.
    def mint_successor
      access = ApiToken.mint_oauth(account_id:, scopes: scope_list, client_id:, resource:)
      refresh = OAuthRefreshToken.mint(account_id:, client_id:, scopes: scope_list,
                                       resource:, access_token_id: access.record.id)
      update(replaced_by_id: refresh.record.id)
      [access, refresh]
    end

    # Atomically flips a still-live row to revoked, returning the rows changed: 1 for the
    # caller that wins the race, 0 for a reuse of an already-rotated token.
    def claim!
      OAuthRefreshToken.where(id:, revoked_at: nil).update(revoked_at: Time.now)
    end

    def scope_list
      Array(scopes).map(&:to_s)
    end
  end
end

