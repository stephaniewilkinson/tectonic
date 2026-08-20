# frozen_string_literal: true

require 'openssl'
# rodauth-oauth's oauth_jwt feature picks its JWT backend at load time by checking
# whether JWT is already defined, so the jwt gem must be required before the rodauth
# configuration enables the feature. This file is required ahead of that block.
require 'jwt'

class Tectonic < Roda
  # The RSA keypair the OAuth authorization server signs JWT access tokens with, and
  # the MCP resource server verifies them against. In production both the app (as AS)
  # and the MCP endpoint (as RS) run in one process, so the same public key verifies
  # locally with no introspection round-trip. The private key comes from the
  # environment in production; outside it an ephemeral pair is generated at boot so
  # tests and local runs need no key management.
  module OAuthKeys
    ALGORITHM = 'RS256'
    PRODUCTION = %w[production staging].freeze

    module_function

    # The signing key, as `{ "RS256" => key }` for rodauth-oauth's oauth_jwt_keys.
    def signing_keys
      { ALGORITHM => private_key }
    end

    # The verification key, as `{ "RS256" => key }` for oauth_jwt_public_keys and the
    # resource server's local verify.
    def verification_keys
      { ALGORITHM => public_key }
    end

    def private_key
      keypair.first
    end

    def public_key
      keypair.last
    end

    # Loaded once. A PEM in OAUTH_JWT_PRIVATE_KEY is authoritative; with none we refuse
    # to boot in production and otherwise mint a throwaway pair.
    def keypair
      @keypair ||= build_keypair
    end

    def build_keypair
      pem = ENV.fetch('OAUTH_JWT_PRIVATE_KEY', nil)
      raise 'OAUTH_JWT_PRIVATE_KEY must be set in production' if pem.nil? && production?

      key = pem ? OpenSSL::PKey::RSA.new(pem) : OpenSSL::PKey::RSA.generate(2048)
      [key, key.public_key]
    end

    def production?
      PRODUCTION.include?(ENV.fetch('RACK_ENV', nil))
    end
  end
end

