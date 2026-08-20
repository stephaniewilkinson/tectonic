# frozen_string_literal: true

require 'uri'
require 'roda'

class Tectonic < Roda
  module OAuth
    # Which callbacks a client may register. Dynamic client registration is open here
    # by design -- an LLM registers itself with no prior account -- and rodauth-oauth
    # asks only whether the redirect_uri parses and carries no fragment. That is not
    # enough on its own: a registered client can be walked through the consent screen
    # by anyone, so a callback pointing anywhere turns one careless approval into a
    # stolen authorization code. The allow-list is the gate.
    #
    # An entry matches a candidate when the scheme, host, port, query, and path all
    # agree, with two deliberate exceptions. An entry whose path ends in a slash
    # matches any path beneath it, which is how the ChatGPT callback-id form and local
    # development are covered. And when both entry and candidate are loopback the port
    # is ignored, because a native client binds an ephemeral port it cannot know in
    # advance (RFC 8252 section 7.3); nothing else about a loopback URI is forgiven.
    #
    # OAUTH_REDIRECT_URI_ALLOWLIST replaces the defaults with a whitespace- or
    # comma-separated list, so a new client can be admitted without a deploy.
    module RedirectUri
      # The published callbacks of the two clients this server exists for, plus
      # loopback for local development and for native clients. Claude uses the same
      # path on both of its domains. ChatGPT uses the stable redirect only for an
      # authorization server that advertises issuer identification, which this one does
      # not, so the per-connector https://chatgpt.com/connector/oauth/<callback id>
      # form is the one it will actually present.
      DEFAULT = %w[
        https://claude.ai/api/mcp/auth_callback
        https://claude.com/api/mcp/auth_callback
        https://chatgpt.com/connector_platform_oauth_redirect
        https://chatgpt.com/connector/oauth/
        http://localhost/
        http://127.0.0.1/
        http://[::1]/
      ].freeze

      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      module_function

      # Whether a client may register this callback.
      def allowed?(candidate)
        uri = parse(candidate)
        return false unless uri&.scheme && uri.hostname && uri.fragment.nil?

        allow_list.any? { |entry| match?(parse(entry), uri) }
      end

      def allow_list
        configured = ENV.fetch('OAUTH_REDIRECT_URI_ALLOWLIST', nil).to_s.split(/[\s,]+/)
        configured.empty? ? DEFAULT : configured
      end

      def match?(entry, uri)
        return false unless entry && same_origin?(entry, uri)

        entry.query == uri.query && path_match?(entry, uri)
      end

      # Scheme and host have to agree exactly, and so does the port unless both sides
      # are loopback, which is the one thing RFC 8252 lets vary.
      def same_origin?(entry, uri)
        return false unless entry.scheme == uri.scheme && host(entry) == host(uri)

        entry.port == uri.port || (loopback?(entry) && loopback?(uri))
      end

      # An entry ending in a slash covers every path under it; any other entry is the
      # whole path or nothing.
      def path_match?(entry, uri)
        entry.path.end_with?('/') ? uri.path.start_with?(entry.path) : entry.path == uri.path
      end

      def loopback?(uri)
        uri.scheme == 'http' && LOOPBACK_HOSTS.include?(host(uri))
      end

      def host(uri)
        uri.hostname.to_s.downcase
      end

      def parse(uri)
        URI.parse(uri.to_s)
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

