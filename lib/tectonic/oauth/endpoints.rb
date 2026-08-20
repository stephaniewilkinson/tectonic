# frozen_string_literal: true

require 'json'
require_relative 'metadata'
require_relative 'authorization'
require_relative 'registration'
require_relative 'revocation'
require_relative 'token_grant'
require_relative '../oauth_authorization_code'

class Tectonic < Roda
  # The Roda glue for the OAuth endpoints: thin instance methods the route tree in app.rb
  # calls, each delegating to an OAuth service object. Kept out of app.rb so that file
  # stays a map of the routes rather than their implementation.
  module OAuthEndpoints
    # The most a registration body may be. /register is unauthenticated by design, so the
    # size of the allocation it causes must not be the caller's to choose.
    MAX_BODY_BYTES = 16_384

    # The consent screen is the page where a user hands out access to their account, so
    # it gets a tighter policy than the rest of the site: the stylesheet CDN is the only
    # script origin, nothing may frame it, and there is no base tag to hijack. Its layout
    # loads no analytics or charting bundle, so this is the whole of what it needs.
    # form-action is deliberately absent: approving consent POSTs to this app and is
    # answered with a 302 to the client's callback, and browsers disagree about whether
    # form-action applies across that redirect. Restricting it would risk breaking the
    # one flow this page exists to serve, for a directive that guards against an
    # injected form the escaping here already prevents.
    CONSENT_CSP = "default-src 'none'; script-src https://cdn.tailwindcss.com; " \
                  "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " \
                  "font-src 'self'; frame-ancestors 'none'; base-uri 'none'"

    # Renders a JSON body with the given status, for the metadata/register/token endpoints.
    def oauth_json(data, status = 200)
      response.status = status
      response['Content-Type'] = 'application/json'
      data.to_json
    end

    # POST /register (RFC 7591): register a public client from the JSON body.
    def oauth_register(request)
      body = oauth_json_body(request)
      return oauth_json(oauth_malformed_body, 400) unless body

      status, data = OAuth::Registration.call(body)
      oauth_json(data, status)
    end

    # POST /token: form-encoded only. A non-form body is a 400 invalid_request rather than
    # a 415, because a 415 breaks claude.ai. Then dispatch to the grant handlers.
    def oauth_token(request)
      return oauth_json(oauth_unsupported_media, 400) unless oauth_form?(request)

      params = oauth_params(request)
      return oauth_json(oauth_unreadable_params, 400) unless params

      status, data = OAuth::TokenGrant.call(params)
      oauth_json(data, status)
    end

    # POST /revoke (RFC 7009): revoke the presented token and everything issued with it.
    # An unreadable body names no token, and naming no token is already a 200.
    def oauth_revoke(request)
      return oauth_json(oauth_unsupported_media, 400) unless oauth_form?(request)

      status, data = OAuth::Revocation.call(oauth_params(request) || {})
      oauth_json(data, status)
    end

    # GET /authorize: validate, then an error page, an error redirect, a login prompt
    # (stashing the return), or the consent screen for a logged-in user.
    def oauth_authorize_get(request)
      params = oauth_params(request)
      return oauth_error_page unless params

      result = OAuth::Authorization.validate(params)
      return oauth_error_page if result.client_error?
      return request.redirect(result.redirect_error_url) if result.redirect_error?

      rodauth.require_login
      @oauth = result.request
      oauth_view('oauth/consent')
    end

    # POST /authorize: the consent approval, CSRF-checked and bound to the login session.
    # Re-validates, then mints a single-use code and redirects back to the client.
    def oauth_authorize_post(request)
      check_csrf!
      rodauth.require_login
      params = oauth_params(request)
      return oauth_error_page unless params

      result = OAuth::Authorization.validate(params)
      return oauth_error_page if result.client_error?
      return request.redirect(result.redirect_error_url) if result.redirect_error?

      oauth_grant_code(request, result.request)
    end

    private

    def oauth_grant_code(request, authorize_request)
      account_id = rodauth.account_from_session[:id]
      code = OAuthAuthorizationCode.mint(request: authorize_request, account_id:)
      request.redirect authorize_request.success_redirect(code.raw)
    end

    # The parsed registration body, or nil when it is oversized, unparseable, or not a
    # JSON object. Every caller treats nil as a 400, so none of those reach Registration
    # as something it would raise on.
    def oauth_json_body(request)
      raw = oauth_read_body(request)
      return unless raw

      parsed = JSON.parse(raw)
      parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    # At most MAX_BODY_BYTES, whatever Content-Length claims. Reading one byte past the
    # cap is what tells an oversized body from an exactly-sized one.
    def oauth_read_body(request)
      raw = request.body&.read(MAX_BODY_BYTES + 1)
      raw if raw && raw.bytesize <= MAX_BODY_BYTES
    end

    # The request's parameters, or nil when Rack cannot read them. A bad percent-escape or
    # an over-nested query raises out of request.params, and every endpoint here is
    # unauthenticated, so without this a caller could choose a 500 over an RFC error body.
    def oauth_params(request)
      request.params
    rescue Rack::BadRequest
      nil
    end

    def oauth_form?(request)
      request.content_type.to_s.include?('application/x-www-form-urlencoded')
    end

    def oauth_unsupported_media
      { error: 'invalid_request',
        error_description: 'this endpoint requires application/x-www-form-urlencoded' }
    end

    def oauth_unreadable_params
      { error: 'invalid_request', error_description: 'the request parameters could not be read' }
    end

    def oauth_malformed_body
      { error: 'invalid_client_metadata',
        error_description: "the body must be a JSON object of at most #{MAX_BODY_BYTES} bytes" }
    end

    def oauth_error_page
      response.status = 400
      oauth_view('oauth/error')
    end

    # An OAuth browser page: the stripped-down layout and the tighter policy, together,
    # so neither can be applied to one of these pages without the other.
    def oauth_view(template)
      response['Content-Security-Policy'] = CONSENT_CSP
      view(template, layout: 'oauth/layout')
    end
  end

  include OAuthEndpoints
end

