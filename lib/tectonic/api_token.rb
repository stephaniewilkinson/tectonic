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

    # Resolves a raw bearer token to its live row, or nil when it is unknown, expired,
    # or revoked. The lookup is by digest, so the raw value is never compared in SQL.
    def self.verify(raw)
      return if raw.nil? || raw.empty?

      token = where(token_digest: digest(raw)).first
      return unless token&.active?

      token
    end

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw)
    end

    # A token is usable until it is revoked or its expiry passes.
    def active?
      revoked_at.nil? && (expires_at.nil? || expires_at > Time.now)
    end

    # Records that the token was just used to authenticate a request.
    def touch_last_used!
      update(last_used_at: Time.now)
    end

    # Soft-revoke: the row stays so audit rows keep a live foreign key to it.
    def revoke!
      update(revoked_at: Time.now) unless revoked_at
    end

    # Plain array of granted scope strings, decoupled from the Postgres array type.
    def scope_list
      Array(scopes).map(&:to_s)
    end
  end
end

