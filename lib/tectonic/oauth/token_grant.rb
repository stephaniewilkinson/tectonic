# frozen_string_literal: true

require_relative '../api_token'
require_relative '../oauth_authorization_code'
require_relative '../oauth_refresh_token'
require_relative 'pkce'

class Tectonic < Roda
  module OAuth
    # The token endpoint's logic. Two grants: authorization_code (redeem a code for an
    # access + refresh token, after re-checking every binding and verifying PKCE) and
    # refresh_token (rotate). Every method returns [status, body_hash]; errors are RFC
    # 6749 codes so the client can react. The redemption and the rotation are each an
    # atomic claim, so a replayed code or a reused refresh token cannot mint twice.
    module TokenGrant
      module_function

      ACCESS_LIFETIME = ApiToken::OAUTH_ACCESS_LIFETIME

      # Dispatches on grant_type.
      def call(params)
        case params['grant_type']
        when 'authorization_code' then authorization_code(params)
        when 'refresh_token' then refresh(params)
        else error('unsupported_grant_type')
        end
      end

      def authorization_code(params)
        code = OAuthAuthorizationCode.verify(params['code'])
        reason = code_rejection(code, params)
        return error('invalid_grant', reason) if reason
        return error('invalid_grant', 'authorization code already used') unless code.consume! == 1

        issue(code.account_id, code.client_id, code.scope_list, code.resource)
      end

      # The first reason to reject a code exchange, or nil to proceed. Confirms the code is
      # live and that the client, redirect_uri, and resource match what it was bound to,
      # then that the PKCE verifier proves the stored challenge.
      def code_rejection(code, params)
        return 'unknown or expired authorization code' unless code&.active?
        return 'client_id mismatch' unless code.client_id == params['client_id']
        return 'redirect_uri mismatch' unless code.redirect_uri == params['redirect_uri']
        return 'resource mismatch' unless resource_ok?(code.resource, params['resource'])
        return 'PKCE verification failed' unless pkce_ok?(code, params)

        nil
      end

      def pkce_ok?(code, params)
        Pkce.verify(params['code_verifier'], code.code_challenge, code.code_challenge_method)
      end

      def refresh(params)
        token = OAuthRefreshToken.verify(params['refresh_token'])
        return error('invalid_grant', 'unknown or revoked refresh token') unless token&.active?
        return error('invalid_grant', 'client_id mismatch') unless token.client_id == params['client_id']

        rotated = token.rotate!
        return error('invalid_grant', 'refresh token already used') unless rotated

        response(rotated[0], rotated[1], token.scope_list)
      end

      # Mints an access token plus its refresh token for a fresh authorization.
      def issue(account_id, client_id, scopes, resource)
        access = ApiToken.mint_oauth(account_id:, scopes:, client_id:, resource:)
        refresh = OAuthRefreshToken.mint(account_id:, client_id:, scopes:, resource:,
                                         access_token_id: access.record.id)
        response(access, refresh, scopes)
      end

      def response(access, refresh, scopes)
        [200, {
          access_token: access.raw, token_type: 'Bearer', expires_in: ACCESS_LIFETIME,
          refresh_token: refresh.raw, scope: Array(scopes).join(' ')
        }]
      end

      # The audience requirement is met when the token request omits resource or repeats
      # the value the code was bound to; a different resource is a mismatch.
      def resource_ok?(bound, requested)
        requested.to_s.empty? || requested == bound
      end

      def error(code, description = nil)
        body = { error: code }
        body[:error_description] = description if description
        [400, body]
      end
    end
  end
end

