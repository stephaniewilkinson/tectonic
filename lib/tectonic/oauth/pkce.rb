# frozen_string_literal: true

require 'digest'
require 'base64'
require 'rack/utils'

class Tectonic < Roda
  module OAuth
    # Proof Key for Code Exchange (RFC 7636), S256 only. The authorize request registers
    # a code_challenge; the token request presents the code_verifier. We recompute the
    # challenge from the verifier and compare in constant time, so a stolen authorization
    # code is useless without the verifier that only the original client holds.
    module Pkce
      module_function

      # Whether `verifier` proves knowledge of the secret behind `challenge`. Only S256 is
      # accepted; a missing verifier/challenge or the plain method is a hard no.
      def verify(verifier, challenge, method)
        return false unless method == 'S256'
        return false if verifier.to_s.empty? || challenge.to_s.empty?

        expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        Rack::Utils.secure_compare(expected, challenge)
      end
    end
  end
end

