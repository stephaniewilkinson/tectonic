# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  module OAuth
    # Names the grant inside every JWT access token, so the resource server can tell a
    # live grant from a revoked one.
    #
    # rodauth-oauth's default claims (iss, iat, sub, client_id, exp, aud) say nothing
    # about which grant a token came from, and a JWT is verified by signature alone. So
    # revoking a grant stopped the issuing of new tokens but did nothing to the ones
    # already handed out: a stolen access token kept working for its full hour, which is
    # exactly the window an attacker needs. Carrying the grant id closes that -- see
    # MCP::AccessToken, which refuses a token whose grant is gone.
    #
    # `gid` is a private claim: RFC 9068 reserves jti for a per-token identifier, and
    # many tokens share one grant, so jti would be the wrong name for this.
    module GrantBoundTokens
      private

      def jwt_claims(oauth_grant)
        super.merge(gid: oauth_grant[oauth_grants_id_column])
      end
    end
  end
end

