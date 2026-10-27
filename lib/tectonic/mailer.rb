# frozen_string_literal: true

require 'http'
require 'json'
require 'securerandom'

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
    # Four seconds a try and two tries, so the worst case stays under the ten seconds a
    # single try used to get. This is on the request path, and a provider that is merely
    # slow must not hold a Puma thread open behind somebody's sign-up -- but one that drops
    # a single request (TECTONIC-3: a confirmation timed out on /create-account) should not
    # cost that person their email either. Resend normally answers in well under a second.
    TIMEOUT = 4
    ATTEMPTS = 2
    # Only the failures where trying again could help. A refusal (4xx) comes back as a
    # response, not one of these, and sending it again would be refused again.
    RETRYABLE = [HTTP::TimeoutError, HTTP::ConnectionError].freeze

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

      post_with_retry(to:, subject:, text:)
    rescue StandardError => e
      # Any transport failure at all: DNS, TLS, timeout. Reported, never raised, for the
      # reason on the module above.
      report("could not send #{subject.inspect} to #{to}: #{e.class}: #{e.message}", e)
      false
    end

    # One key for every try. A timeout does not mean Resend dropped the request -- it may have
    # sent the email and been slow to say so -- and the key is what makes the second try a
    # no-op rather than a second copy in somebody's inbox.
    def post_with_retry(to:, subject:, text:)
      key = SecureRandom.uuid
      attempt = 0
      begin
        attempt += 1
        post(to:, subject:, text:, key:)
      rescue *RETRYABLE
        retry if attempt < ATTEMPTS
        raise
      end
    end

    def post(to:, subject:, text:, key:)
      response = HTTP.timeout(TIMEOUT)
                     .auth("Bearer #{api_key}")
                     .headers('Idempotency-Key' => key)
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

