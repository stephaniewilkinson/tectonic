# frozen_string_literal: true

require 'uri'
require_relative 'db'

class Tectonic < Roda
  # The first page a signed-out browser loaded here, kept in its session until it signs up.
  # #691; see migrate/060 for what each field is and why.
  #
  # First rather than last: the question the signup report asks is which channel brought
  # somebody, and the page they reached through it is the first one. Anything they clicked
  # afterwards is this site's own navigation.
  module FirstTouch
    KEY = 'first_touch'
    # Long enough for any real host, tag or path; short enough that a crafted URL cannot
    # bloat a cookie-backed session.
    LIMIT = 200

    module_function

    # Noted once per session, for a page a person asked for: a GET that accepts HTML, from a
    # browser nobody is signed in to. OAuth clients fetching metadata and the assistant's own
    # requests are none of those, so they never start a session here.
    def note(session, request, signed_in:)
      return if signed_in || session.key?(KEY)
      return unless request.get? && request.env['HTTP_ACCEPT'].to_s.include?('text/html')

      session[KEY] = { 'host' => referrer_host(request), 'ref' => tag(request.params),
                       'path' => request.path[0, LIMIT] }
    end

    # Copied onto the account at sign-up, while the session still holds it: verifying the
    # address later signs the account in and starts a fresh session.
    def record(account_id, session)
      touch = session[KEY]
      return unless touch.is_a?(Hash)

      DB[:accounts].where(id: account_id).update(signup_referrer_host: touch['host'], signup_ref: touch['ref'],
                                                 signup_landing_path: touch['path'])
    end

    # The referrer's host alone, and nothing when it is this site: a returning browser whose
    # session expired mid-visit came from here, not from anywhere worth counting.
    def referrer_host(request)
      host = URI(request.referer.to_s).host
      host unless host.nil? || host == request.host
    rescue URI::InvalidURIError
      nil
    end

    def tag(params)
      value = params['ref'] || params['utm_source']
      value.is_a?(String) && !value.strip.empty? ? value.strip.downcase[0, LIMIT] : nil
    end
  end
end

