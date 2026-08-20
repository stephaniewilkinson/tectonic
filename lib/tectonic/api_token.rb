# frozen_string_literal: true

require 'securerandom'
require 'digest'
require_relative 'db'

class Tectonic < Roda
  # A bearer credential for the MCP endpoint. The raw value exists only for the
  # instant it is minted and printed; the row keeps just its SHA-256 digest, so the
  # database never holds anything a caller could authenticate with.
  class ApiToken < Sequel::Model
    # A freshly minted token and the model row behind it. `raw` is returned once and
    # never recoverable, so the caller prints it immediately.
    Minted = Struct.new(:raw, :record)

    # Mints a token for an account: 32 random bytes, base64url encoded, stored as its
    # digest alongside the granted scopes and an optional name/expiry. Returns Minted
    # so the caller can show the raw value exactly once.
    def self.mint(account_id:, scopes:, name: nil, expires_at: nil)
      raw = SecureRandom.urlsafe_base64(32)
      record = create(
        account_id:,
        token_digest: digest(raw),
        name:,
        scopes: Sequel.pg_array(Array(scopes).map(&:to_s), :text),
        expires_at:
      )
      Minted.new(raw, record)
    end

    # An OAuth access token: an api_tokens row with kind 'oauth', tagged with the client
    # it was issued to and the resource (audience) it is valid for, so the MCP auth
    # middleware can reject a token presented at any other endpoint. ~1 hour expiry.
    OAUTH_ACCESS_LIFETIME = 3600

    def self.mint_oauth(account_id:, scopes:, client_id:, resource:)
      raw = SecureRandom.urlsafe_base64(32)
      record = create(
        account_id:, token_digest: digest(raw), kind: 'oauth', client_id:, resource:,
        scopes: Sequel.pg_array(Array(scopes).map(&:to_s), :text),
        expires_at: Time.now + OAUTH_ACCESS_LIFETIME
      )
      Minted.new(raw, record)
    end

    # Resolves a raw bearer token to its live row, or nil when it is unknown, expired,
    # or revoked. The lookup is by digest, so the raw value is never compared in SQL.
    def self.verify(raw)
      token = locate(raw)
      return unless token&.active?

      token
    end

    # The row for a raw token whether or not it is still usable. Revocation needs this:
    # an expired access token can still have a live refresh token behind it, so refusing
    # to find it would leave that chain alive.
    def self.locate(raw)
      return if raw.nil? || raw.empty?

      where(token_digest: digest(raw)).first
    end

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw)
    end

    # A token is usable until it is revoked or its expiry passes.
    def active?
      revoked_at.nil? && (expires_at.nil? || expires_at > Time.now)
    end

    # An OAuth-issued token, as opposed to a personal access token. Only OAuth tokens
    # carry an audience the MCP auth middleware enforces; PATs (kind 'pat') do not.
    def oauth?
      kind == 'oauth'
    end

    # Records that the token was just used to authenticate a request.
    def touch_last_used!
      update(last_used_at: Time.now)
    end

    # Soft-revoke: the row stays so audit rows keep a live foreign key to it. Revoking an
    # OAuth access token also revokes the refresh tokens that minted it, because a
    # refresh token left alive would mint a replacement within seconds and the revocation
    # would have bought nothing. Written as a dataset update rather than through
    # OAuthRefreshToken so this file stays free of a circular require; the cascade cannot
    # recur, because it touches rows rather than models.
    def revoke!
      return if revoked_at

      update(revoked_at: Time.now)
      db[:oauth_refresh_tokens].where(access_token_id: id, revoked_at: nil)
                               .update(revoked_at: Time.now)
    end

    # A human-readable name for provenance lines. Only an operator-minted token carries a
    # name, so an OAuth token falls back to naming the client it was issued to; without
    # this every OAuth-created row would report the nil that means "a human made this".
    def label
      return name if name

      oauth? ? "OAuth client #{client_id}" : 'an API token'
    end

    # Plain array of granted scope strings, decoupled from the Postgres array type.
    def scope_list
      Array(scopes).map(&:to_s)
    end
  end
end

