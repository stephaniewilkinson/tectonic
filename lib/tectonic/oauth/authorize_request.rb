# frozen_string_literal: true

require 'uri'
require 'rack/utils'

class Tectonic < Roda
  module OAuth
    # A fully validated /authorize request: exactly the fields an authorization code is
    # bound to. The GET handler renders it on the consent screen and the POST handler
    # mints a code from it, so the token minted later can only ever carry values that
    # passed validation here.
    AuthorizeRequest = Struct.new(
      :client, :client_id, :redirect_uri, :scopes,
      :code_challenge, :code_challenge_method, :resource, :state,
      keyword_init: true
    ) do
      # The host the code will be returned to, shown on the consent screen.
      def redirect_host
        URI.parse(redirect_uri).host
      rescue URI::InvalidURIError
        redirect_uri
      end

      # The success redirect back to the client: the registered URI with the code and,
      # if the client sent one, the state echoed back so it can detect CSRF on its side.
      def success_redirect(code)
        query = { code: code }
        query[:state] = state unless state.to_s.empty?
        "#{redirect_uri}?#{Rack::Utils.build_query(query)}"
      end
    end
  end
end

