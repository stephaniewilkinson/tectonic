# frozen_string_literal: true

require 'json'
require_relative 'metadata'
require_relative 'authorization'
require_relative 'registration'
require_relative 'token_grant'
require_relative '../oauth_authorization_code'

class Tectonic < Roda
  # The Roda glue for the OAuth endpoints: thin instance methods the route tree in app.rb
  # calls, each delegating to an OAuth service object. Kept out of app.rb so that file
  # stays a map of the routes rather than their implementation.
  module OAuthEndpoints
    # Session key holding the /authorize URL to return to after an interrupted login.
    # app.rb's login_redirect reads it, so both sides name it through this constant.
    OAUTH_RETURN_KEY = 'oauth.return_to'

    # Renders a JSON body with the given status, for the metadata/register/token endpoints.
    def oauth_json(data, status = 200)
      response.status = status
      response['Content-Type'] = 'application/json'
      data.to_json
    end

    # POST /register (RFC 7591): register a public client from the JSON body.
    def oauth_register(request)
      status, data = OAuth::Registration.call(oauth_json_body(request))
      oauth_json(data, status)
    end

    # POST /token: form-encoded only. A non-form body is a 400 invalid_request rather than
    # a 415, because a 415 breaks claude.ai. Then dispatch to the grant handlers.
    def oauth_token(request)
      return oauth_json(oauth_unsupported_media, 400) unless oauth_form?(request)

      status, data = OAuth::TokenGrant.call(request.params)
      oauth_json(data, status)
    end

    # GET /authorize: validate, then an error page, an error redirect, a login prompt
    # (stashing the return), or the consent screen for a logged-in user.
    def oauth_authorize_get(request)
      result = OAuth::Authorization.validate(request.params)
      return oauth_error_page if result.client_error?
      return request.redirect(result.redirect_error_url) if result.redirect_error?

      oauth_require_login(request)
      @oauth = result.request
      view('oauth/consent')
    end

    # POST /authorize: the consent approval, CSRF-checked and bound to the login session.
    # Re-validates, then mints a single-use code and redirects back to the client.
    def oauth_authorize_post(request)
      check_csrf!
      rodauth.require_login
      result = OAuth::Authorization.validate(request.params)
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

    # Sends an unauthenticated user to log in, remembering the authorize URL so app.rb's
    # login_redirect returns them here to finish the flow.
    def oauth_require_login(request)
      return if rodauth.logged_in?

      session[OAUTH_RETURN_KEY] = request.fullpath
      rodauth.require_login
    end

    def oauth_json_body(request)
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      {}
    end

    def oauth_form?(request)
      request.content_type.to_s.include?('application/x-www-form-urlencoded')
    end

    def oauth_unsupported_media
      { error: 'invalid_request',
        error_description: 'the token endpoint requires application/x-www-form-urlencoded' }
    end

    def oauth_error_page
      response.status = 400
      view('oauth/error')
    end
  end

  include OAuthEndpoints
end

