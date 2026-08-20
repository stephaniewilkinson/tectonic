# frozen_string_literal: true

require_relative '../api_token'
require_relative '../oauth_authorization_code'
require_relative '../oauth_refresh_token'
require_relative 'grant'
require_relative 'params'
require_relative 'pkce'

class Tectonic < Roda
  module OAuth
    # The token endpoint's logic. Two grants: authorization_code (redeem a code for an
    # access token, after re-checking every binding and verifying PKCE) and refresh_token
    # (rotate). Every method returns [status, body_hash]; errors are RFC 6749 codes so the
    # client can react. The redemption and the rotation are each an atomic claim, so a
    # replayed code or a reused refresh token cannot mint twice -- and a reused refresh
    # token additionally revokes every token descended from the same consent.
    module TokenGrant
      module_function

      ACCESS_LIFETIME = ApiToken::OAUTH_ACCESS_LIFETIME
      # The scope that buys a refresh token. Without it a grant lasts exactly as long as
      # the access token, which is what a consent screen listing only 'read' promised.
      OFFLINE_ACCESS = 'offline_access'

      # Dispatches on grant_type.
      def call(raw_params)
        params = Params.strings(raw_params)
        return error('invalid_request', 'every parameter must be a single value') unless params

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

        issue(code)
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
        return error('invalid_grant', 'unknown refresh token') unless token
        return replayed(token) if token.revoked_at

        reason = refresh_rejection(token, params)
        return error('invalid_grant', reason) if reason

        rotated = token.rotate!
        rotated ? response(rotated[0], rotated[1], token.scope_list) : replayed(token)
      end

      # The first reason to refuse a rotation of a still-live token, or nil to proceed.
      # A revoked one never reaches here; that is reuse, and it is handled before this.
      def refresh_rejection(token, params)
        return 'expired refresh token' unless token.active?
        return 'client_id mismatch' unless token.client_id == params['client_id']

        nil
      end

      # A refresh token presented after it was already spent or revoked. The chain has to
      # be assumed leaked, so every token descended from the same consent is revoked
      # (RFC 9700 section 4.14.2) rather than only this replay being refused.
      def replayed(token)
        OAuthRefreshToken.revoke_family!(token.grant_id)
        error('invalid_grant', 'refresh token already used; this grant has been revoked')
      end

      # Opens a grant for a freshly redeemed code and mints its first token pair.
      def issue(code)
        grant = Grant.start(account_id: code.account_id, client_id: code.client_id,
                            scopes: code.scope_list, resource: code.resource)
        access = ApiToken.mint_oauth(account_id: grant.account_id, scopes: grant.scopes,
                                     client_id: grant.client_id, resource: grant.resource)
        response(access, refresh_token_for(grant, access), grant.scopes)
      end

      # The grant's refresh token, or nil when offline_access was never granted.
      def refresh_token_for(grant, access)
        return unless grant.scopes.include?(OFFLINE_ACCESS)

        OAuthRefreshToken.mint(grant:, access_token_id: access.record.id)
      end

      def response(access, refresh, scopes)
        body = { access_token: access.raw, token_type: 'Bearer', expires_in: ACCESS_LIFETIME,
                 scope: Array(scopes).join(' ') }
        body[:refresh_token] = refresh.raw if refresh
        [200, body]
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

