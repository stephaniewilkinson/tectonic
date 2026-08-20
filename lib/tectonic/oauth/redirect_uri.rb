# frozen_string_literal: true

require 'uri'

class Tectonic < Roda
  module OAuth
    # The redirect_uri allow-policy. Two questions live here: whether a URI may be
    # registered at all (acceptable?) and whether an incoming URI matches a registered
    # one (match?). Non-loopback URIs must match exactly, which is what stops an open
    # redirector; loopback URIs match on everything but the port, because a native client
    # binds an ephemeral localhost port it cannot know at registration time (RFC 8252
    # section 7.3). The port is the only thing the comparison forgives: scheme, host,
    # path, and query all have to agree, so port-agnostic never becomes path-agnostic.
    module RedirectUri
      module_function

      # The one public callback we accept, matched exactly.
      CLAUDE_CALLBACK = 'https://claude.ai/api/mcp/auth_callback'
      # URI.parse keeps the brackets on an IPv6 host, so the bracketed form is what a
      # parsed `http://[::1]/cb` actually compares against.
      LOOPBACK_HOSTS = ['localhost', '127.0.0.1', '::1', '[::1]'].freeze
      # A redirect_uri is a URI-reference with no fragment (RFC 6749 section 3.1.2), and
      # an unbounded one is a storage-exhaustion vector on an open registration endpoint.
      MAX_LENGTH = 512

      # Whether a redirect_uri may be registered: the claude.ai callback or a loopback,
      # in either case within length and carrying no fragment.
      def acceptable?(uri)
        return false unless well_formed?(uri)

        uri == CLAUDE_CALLBACK || loopback?(uri)
      end

      # Whether an incoming `candidate` matches a `registered` URI. Both loopback: compare
      # everything but the port. Otherwise the whole string must match.
      def match?(registered, candidate)
        return registered == candidate unless loopback?(registered) && loopback?(candidate)

        key(registered) == key(candidate)
      end

      def loopback?(uri)
        parsed = parse(uri)
        !parsed.nil? && parsed.scheme == 'http' && LOOPBACK_HOSTS.include?(parsed.host&.downcase)
      end

      # Everything about a loopback URI that has to agree, which is everything the URI
      # carries except its port.
      def key(uri)
        parsed = parse(uri)
        [parsed.scheme, parsed.host&.downcase, parsed.path, parsed.query]
      end

      # Registrable shape: parses, is within length, names no fragment, and percent-encodes
      # correctly. A fragment would be dropped by the browser on the way back, so it can
      # never be honoured; a bare trailing '#' parses to an empty fragment and is refused
      # the same way. A broken escape is refused here because the redirect builder has to
      # re-parse this query later, and by then there is no way to answer the client at all.
      def well_formed?(uri)
        text = uri.to_s
        parsed = parse(text)
        !parsed.nil? && text.bytesize <= MAX_LENGTH && parsed.fragment.nil? && escaped?(text)
      end

      # Every '%' begins a two-hex-digit escape.
      def escaped?(text)
        !text.match?(/%(?!\h\h)/)
      end

      def parse(uri)
        URI.parse(uri.to_s)
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

