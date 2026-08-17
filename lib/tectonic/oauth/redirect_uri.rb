# frozen_string_literal: true

require 'uri'

class Tectonic < Roda
  module OAuth
    # The redirect_uri allow-policy. Two questions live here: whether a URI may be
    # registered at all (acceptable?) and whether an incoming URI matches a registered
    # one (match?). Non-loopback URIs must match exactly, which is what stops an open
    # redirector; loopback URIs match port-agnostically because a native client binds an
    # ephemeral localhost port it cannot know at registration time (RFC 8252 section 7.3).
    module RedirectUri
      module_function

      # The one public callback we accept, matched exactly.
      CLAUDE_CALLBACK = 'https://claude.ai/api/mcp/auth_callback'
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

      # Whether a redirect_uri may be registered: the claude.ai callback or a loopback.
      def acceptable?(uri)
        uri == CLAUDE_CALLBACK || loopback?(uri)
      end

      # Whether an incoming `candidate` matches a `registered` URI. Both loopback: compare
      # scheme/host/path and ignore the port. Otherwise the whole string must match.
      def match?(registered, candidate)
        return registered == candidate unless loopback?(registered) && loopback?(candidate)

        key(registered) == key(candidate)
      end

      def loopback?(uri)
        parsed = parse(uri)
        !parsed.nil? && parsed.scheme == 'http' && LOOPBACK_HOSTS.include?(parsed.host)
      end

      def key(uri)
        parsed = parse(uri)
        [parsed.scheme, parsed.host, parsed.path]
      end

      def parse(uri)
        URI.parse(uri.to_s)
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

