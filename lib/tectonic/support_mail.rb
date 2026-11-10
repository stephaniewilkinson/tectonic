# frozen_string_literal: true

require 'base64'
require 'http'
require 'json'
require 'openssl'
require 'rack/utils'
require_relative 'mailer'

class Tectonic < Roda
  # Mail to support@tectonicplates.app, passed on to a person. #682.
  #
  # The privacy policy names this address as the way to see or delete your data, so it has to
  # reach somebody. The domain had no MX records at all; the owner chose to receive through
  # Resend, which already sends this app's mail, over a separate forwarding service.
  #
  # Resend does not forward on its own. It accepts the message, then POSTs an `email.received`
  # webhook carrying metadata only -- "Webhooks do not include the email body, headers, or
  # attachments" (resend.com/docs/webhooks/emails/received). So this verifies that POST, fetches
  # the message from the receiving API, and sends it on with the existing sender. Resend's own
  # SDK forward helper does the same two calls; there is no single REST endpoint for it.
  #
  # Where it goes is SUPPORT_EMAIL_FORWARD_TO, an environment variable rather than a constant, so a
  # personal inbox never appears in a public repository. Reply-To is the original sender, so
  # answering from that inbox answers the person who wrote.
  #
  # Attachments are listed, not carried: forwarding them means downloading and re-encoding each
  # one on the request path, for an address that exists to receive "please delete my data". The
  # originals stay in Resend's dashboard under Receiving.
  module SupportMail
    RECEIVED = 'https://api.resend.com/emails/receiving/%s'
    ADDRESS = 'support@tectonicplates.app'
    # Svix, which signs Resend's webhooks, leaves the window to the receiver. Five minutes is the
    # window its own libraries use: long enough for clock skew, short enough that a captured
    # request cannot be replayed later.
    TOLERANCE = 5 * 60
    TIMEOUT = 8

    module_function

    def secret = ENV.fetch('RESEND_WEBHOOK_SECRET', '').to_s
    def forward_to = ENV.fetch('SUPPORT_EMAIL_FORWARD_TO', '').to_s

    # Svix's scheme (docs.svix.com/receiving/verifying-payloads/how-manual): HMAC-SHA256 over
    # "id.timestamp.body" with the base64 key after the whsec_ prefix, compared in constant time
    # against any v1 signature in the space-separated header. `request` is the three svix
    # headers and the raw body: id:, timestamp:, signatures:, body:.
    def verified?(request, secret: self.secret, now: Time.now.to_i)
      id, timestamp, signatures, body = request.values_at(:id, :timestamp, :signatures, :body)
      return false if [id, timestamp, signatures, secret].any? { |value| value.to_s.empty? }
      return false if (now - timestamp.to_i).abs > TOLERANCE

      signed?(signatures, signature(secret, "#{id}.#{timestamp}.#{body}"))
    end

    def signed?(signatures, expected)
      signatures.split.any? do |entry|
        version, value = entry.split(',', 2)
        version == 'v1' && Rack::Utils.secure_compare(value.to_s, expected)
      end
    end

    def signature(secret, content)
      key = Base64.decode64(secret.delete_prefix('whsec_'))
      Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', key, content))
    end

    # Fetches the message and sends it on. True when Resend accepted the forward.
    # rubocop:disable Naming/PredicateMethod -- reports whether work landed, as Mailer.deliver does.
    def forward(email_id)
      received = fetch(email_id)
      response = HTTP.timeout(TIMEOUT).auth("Bearer #{Mailer.api_key}")
                     .post(Mailer::ENDPOINT, json: message(received))
      response.status.success?
    end
    # rubocop:enable Naming/PredicateMethod

    def fetch(email_id)
      response = HTTP.timeout(TIMEOUT).auth("Bearer #{Mailer.api_key}").get(format(RECEIVED, email_id))
      raise "Resend answered #{response.status} for received email #{email_id}" unless response.status.success?

      JSON.parse(response.body.to_s)
    end

    def message(received)
      { from: Mailer.sender, to: [forward_to], reply_to: received['from'],
        subject: "[support] #{received['subject']}",
        text: [received['text'] || '(no plain-text part)', footnote(received)].join("\n\n"),
        html: received['html'] }.compact
    end

    def footnote(received)
      names = Array(received['attachments']).map { |attachment| attachment['filename'] }
      lines = ["Sent to support@ by #{received['from']}."]
      lines << "Attachments, in Resend under Receiving: #{names.join(', ')}." unless names.empty?
      lines.join(' ')
    end

    # The endpoint Resend calls. Mounted beside the MCP endpoint in config.ru rather than inside
    # the Roda app, for the reason the MCP one is: the signature covers the exact bytes sent, and
    # this way nothing -- sessions, CSRF, params parsing -- has read or touched the body first.
    #
    # Anything unverified is a 401 and does nothing. A forward that fails is a 500, so Resend
    # retries it: the message is not lost because this app or Resend's API had a bad minute.
    class Webhook
      def call(env)
        return [405, {}, []] unless env['REQUEST_METHOD'] == 'POST'

        body = env['rack.input'].read
        return [401, {}, []] unless verified?(env, body)

        [handle(JSON.parse(body)), {}, []]
      rescue JSON::ParserError
        [400, {}, []]
      rescue StandardError => e
        warn "[support_mail] forward failed: #{e.class}: #{e.message}"
        [500, {}, []]
      end

      # Only mail to the support address is forwarded. Resend webhooks belong to the account,
      # not the domain, and the owner's other domains receive mail too -- without this, all of it
      # would arrive here and be forwarded as tectonic support mail. Anything else, of any event
      # type, is acknowledged and ignored so Resend stops retrying it.
      def handle(event)
        return 200 unless event['type'] == 'email.received' && for_support?(event)

        SupportMail.forward(event.dig('data', 'email_id')) ? 200 : 500
      end

      def for_support?(event)
        Array(event.dig('data', 'to')).any? { |to| to.to_s.downcase.include?(ADDRESS) }
      end

      def verified?(env, body)
        SupportMail.verified?({ id: env['HTTP_SVIX_ID'], timestamp: env['HTTP_SVIX_TIMESTAMP'],
                                signatures: env['HTTP_SVIX_SIGNATURE'].to_s, body: })
      end
    end
  end
end

