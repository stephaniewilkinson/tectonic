# frozen_string_literal: true

require 'uri'
require 'rack/utils'

class Tectonic < Roda
  module OAuth
    # Appends response parameters to a redirect_uri without assuming it has no query of
    # its own. A registered loopback callback is allowed to carry one, so pasting on
    # "?code=..." would produce a URI whose code is unreadable; this merges instead.
    module Redirect
      module_function

      def with(uri, params)
        parsed = URI.parse(uri)
        parsed.query = Rack::Utils.build_query(merged(parsed.query, params))
        parsed.to_s
      end

      # The callback's own query plus the response parameters. Registration refuses a
      # malformed escape, but a row stored before that rule would still raise here, and a
      # 500 on /authorize is worse than losing a client's own query: the response
      # parameters are what has to arrive.
      def merged(existing, params)
        Rack::Utils.parse_query(existing).merge(params.transform_keys(&:to_s))
      rescue ArgumentError
        params.transform_keys(&:to_s)
      end
    end

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
        Redirect.with(redirect_uri, query)
      end
    end
  end
end

