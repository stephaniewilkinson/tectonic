# frozen_string_literal: true

require 'securerandom'
require 'digest'
require_relative 'db'
require_relative 'oauth_client'

class Tectonic < Roda
  # A single-use authorization code. Only its SHA-256 digest is stored; the raw value is
  # returned once, at the redirect. The row records everything the token endpoint must
  # re-check before minting a token: the account, client, redirect_uri, scopes, resource,
  # and the PKCE challenge. used_at marks the one redemption so a replay is refused.
  class OAuthAuthorizationCode < Sequel::Model(:oauth_authorization_codes)
    Minted = Struct.new(:raw, :record)

    LIFETIME = 300 # seconds; short-lived, redeemed immediately after the redirect

    # Mints a code for an already-validated authorize request and the account that just
    # approved it. `request` carries the client/redirect/scope/PKCE/resource binding.
    def self.mint(request:, account_id:)
      raw = SecureRandom.urlsafe_base64(32)
      record = create(
        code_digest: digest(raw), account_id:, client_id: request.client_id,
        redirect_uri: request.redirect_uri, scopes: OAuthClient.pg(request.scopes),
        code_challenge: request.code_challenge, code_challenge_method: request.code_challenge_method,
        resource: request.resource, expires_at: Time.now + LIFETIME
      )
      Minted.new(raw, record)
    end

    # The row for a raw code, or nil. Digest lookup, so the raw value is never in SQL.
    def self.verify(raw)
      return if raw.nil? || raw.empty?

      where(code_digest: digest(raw)).first
    end

    def self.digest(raw)
      Digest::SHA256.hexdigest(raw)
    end

    # Unused and unexpired.
    def active?
      used_at.nil? && expires_at > Time.now
    end

    # Claims the single redemption atomically, returning the number of rows it flipped from
    # unused to used: 1 for the caller that wins, 0 for a replay. Two concurrent exchanges
    # of one code therefore cannot both mint.
    def consume!
      OAuthAuthorizationCode.where(id:, used_at: nil).update(used_at: Time.now)
    end

    def scope_list
      Array(scopes).map(&:to_s)
    end
  end
end

