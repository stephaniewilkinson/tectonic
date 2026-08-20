# frozen_string_literal: true

require 'securerandom'
require 'digest'
require_relative 'db'
require_relative 'api_token'
require_relative 'oauth_client'
require_relative 'oauth/grant'

class Tectonic < Roda
  # A refresh token, stored as a digest and rotated on every use. Redeeming one revokes
  # it, mints a replacement, and records replaced_by_id, so presenting a rotated or
  # revoked token is an invalid_grant and a signal the token was stolen -- which
  # revoke_family! then acts on by killing every token descended from the same consent.
  # Soft-revoked, never deleted, so the rotation chain stays auditable.
  class OAuthRefreshToken < Sequel::Model(:oauth_refresh_tokens)
    Minted = Struct.new(:raw, :record)

    LIFETIME = 30 * 86_400 # seconds; a stale refresh chain ages out after ~30 days

    # Mints a refresh token for a grant, bound to the access token it accompanies. The
    # grant's id and absolute deadline are carried verbatim, so every token in a chain
    # is revocable as one unit and ages out on the same day the first one would have.
    def self.mint(grant:, access_token_id:)
      raw = SecureRandom.urlsafe_base64(32)
      record = create(
        token_digest: digest(raw), account_id: grant.account_id, client_id: grant.client_id,
        resource: grant.resource, access_token_id:, grant_id: grant.id,
        scopes: OAuthClient.pg(grant.scopes), chain_expires_at: grant.expires_at,
        expires_at: Time.now + LIFETIME
      )
      Minted.new(raw, record)
    end

    # The row for a raw token, live or not. Rotation and revocation both need to tell a
    # token that never existed from one that did and was spent, so the liveness check is
    # the caller's (see active?), not this lookup's.
    def self.verify(raw)
      return if raw.nil? || raw.empty?

      where(token_digest: digest(raw)).first
    end

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw)
    end

    # Revokes every token descended from one consent: each refresh token in the chain and
    # the access tokens they minted. This is what a detected reuse costs -- RFC 9700
    # section 4.14.2 -- and it is also how a user revokes a connected client outright.
    #
    # Order is the whole of the correctness here. The refresh rows die FIRST, because they
    # are the only thing that can mint more tokens; only once none is live are the access
    # tokens collected, so a rotation racing this sweep cannot leave behind an access token
    # nothing revokes. The loop covers the rotation that had already claimed its row when
    # the sweep began: its successor commits after the first pass and the next pass takes
    # it. Returns the number of refresh tokens this call revoked, 0 when the grant was
    # already dead -- which is also the short circuit that stops a replayed token from
    # buying an unbounded sweep on every attempt.
    def self.revoke_family!(grant_id)
      db.transaction do
        revoked = kill_refresh_tokens(grant_id)
        revoke_access_tokens(grant_id) if revoked.positive?
        revoked
      end
    end

    # Revokes live refresh rows until a pass finds none, and answers how many fell. Bounded:
    # a rotation can only add a successor by claiming a live row, and after the first pass
    # every such row is revoked and locked by this transaction.
    def self.kill_refresh_tokens(grant_id)
      revoked = 0
      loop do
        claimed = where(grant_id:, revoked_at: nil).update(revoked_at: Time.now)
        break if claimed.zero?

        revoked += claimed
      end
      revoked
    end

    # Every access token the chain ever minted, in one statement. Safe to read only after
    # the refresh rows are dead, because nothing can add another one behind it.
    def self.revoke_access_tokens(grant_id)
      minted = where(grant_id:).select_map(:access_token_id).compact
      ApiToken.where(id: minted, revoked_at: nil).update(revoked_at: Time.now)
    end

    # Every live grant an account has given a client, newest first.
    def self.grants_for(account_id)
      where(account_id:, revoked_at: nil).reverse(:id).all.uniq(&:grant_id)
    end

    # Live until revoked (which rotation does), expired, or past the absolute deadline
    # of the consent it descends from.
    def active?
      revoked_at.nil? && future?(expires_at) && future?(chain_expires_at)
    end

    # Rotates this token: mints a fresh access token and refresh token bound to the same
    # grant, revokes self, and links replaced_by_id. Returns [access, refresh] Minted
    # pairs, or nil when the row was already rotated (reuse), which the token endpoint
    # turns into invalid_grant. The claim is atomic, so a concurrent double-spend cannot
    # mint twice.
    def rotate!
      db.transaction do
        next nil unless claim! == 1

        mint_successor
      end
    end

    # Mints the replacement access + refresh token pair for the same grant and links this
    # row to the new refresh token. Runs inside rotate!'s transaction, only after the
    # atomic claim has succeeded.
    def mint_successor
      access = ApiToken.mint_oauth(account_id:, scopes: scope_list, client_id:, resource:)
      refresh = OAuthRefreshToken.mint(grant: to_grant, access_token_id: access.record.id)
      update(replaced_by_id: refresh.record.id)
      [access, refresh]
    end

    # The grant this token descends from, so a successor inherits the id and the absolute
    # deadline rather than starting a fresh chain on every rotation.
    def to_grant
      OAuth::Grant.new(id: grant_id, account_id:, client_id:, scopes: scope_list,
                       resource:, expires_at: chain_expires_at)
    end

    # Atomically flips a still-live row to revoked, returning the rows changed: 1 for the
    # caller that wins the race, 0 for a reuse of an already-rotated token.
    def claim!
      OAuthRefreshToken.where(id:, revoked_at: nil).update(revoked_at: Time.now)
    end

    def scope_list
      Array(scopes).map(&:to_s)
    end

    private

    def future?(deadline)
      deadline.nil? || deadline > Time.now
    end
  end
end

