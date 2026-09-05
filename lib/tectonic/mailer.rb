# frozen_string_literal: true

require 'http'
require 'json'

class Tectonic < Roda
  # The one email this app sends: a password reset link. #344.
  #
  # Over Resend's HTTP API with the `http` gem, which is already a dependency, rather than
  # through the `resend` gem or Mail and an SMTP connection. There is one endpoint, it takes
  # a JSON body, and adding a gem to make one POST would be more moving parts than the
  # feature has.
  #
  # **It never raises into a request.** Rodauth calls this from inside the reset form's POST,
  # and an exception there would turn "we have sent you an email" into a 500 -- which tells
  # the person their address is wrong when in fact the mail provider is down. Worse, Rodauth
  # has by then already written the reset token, so the link would work while the page said
  # it had failed. A delivery failure is logged and reported to Sentry and the page goes on
  # saying the same thing it says on success, which is also what stops the form being an
  # oracle for which addresses have accounts.
  #
  # Unconfigured is not an error either. RESEND_API_KEY absent means development, the suite,
  # and any checkout that has never sent an email -- so it logs the link instead of sending
  # it, and the flow stays walkable end to end without a key or a network.
  module Mailer
    ENDPOINT = 'https://api.resend.com/emails'
    # Ten seconds, because this is on the request path. A provider that is merely slow must
    # not hold a Puma thread open behind somebody's password reset.
    TIMEOUT = 10

    module_function

    def api_key = ENV.fetch('RESEND_API_KEY', nil).to_s

    # Who the mail comes from. Must be an address on a domain verified with Resend, or the
    # API refuses it -- which is the most common way this is set up wrongly, so the failure
    # is logged with the response body rather than swallowed.
    def sender = ENV.fetch('MAIL_FROM', 'tectonic plates <noreply@tectonicplates.app>')

    def configured? = !api_key.empty?

    # True if the send was accepted, false otherwise. Callers do not branch on it -- the page
    # says the same thing either way -- but the specs do, and so does the log.
    #
    # rubocop:disable Naming/PredicateMethod -- these return a boolean because they report
    # whether work landed, not because they answer a question about state. `deliver?` and
    # `log_instead?` would both be worse names for what they do.
    def deliver(to:, subject:, text:)
      return log_instead(to, subject, text) unless configured?

      post(to:, subject:, text:)
    rescue StandardError => e
      # Any transport failure at all: DNS, TLS, timeout. Reported, never raised, for the
      # reason on the module above.
      report("could not send #{subject.inspect} to #{to}: #{e.class}: #{e.message}", e)
      false
    end

    def post(to:, subject:, text:)
      response = HTTP.timeout(TIMEOUT)
                     .auth("Bearer #{api_key}")
                     .post(ENDPOINT, json: { from: sender, to: [to], subject:, text: })
      return true if response.status.success?

      report("Resend refused #{subject.inspect} to #{to}: #{response.status} #{response.body}")
      false
    end

    # Development and the suite. The link is the whole point of the email, so putting it on
    # stdout means the flow can be walked without a key, a domain or a network -- and means a
    # spec can assert what would have been sent without stubbing HTTP.
    def log_instead(to, subject, text)
      warn "[mailer] RESEND_API_KEY is not set, so nothing was sent.\n  " \
           "to: #{to}\n  subject: #{subject}\n#{text.to_s.lines.map { |line| "  #{line}" }.join}"
      false
    end

    # rubocop:enable Naming/PredicateMethod
    def report(message, exception = nil)
      warn "[mailer] #{message}"
      return unless defined?(::Sentry) && ::Sentry.initialized?

      exception ? ::Sentry.capture_exception(exception) : ::Sentry.capture_message(message)
    end
  end
end

