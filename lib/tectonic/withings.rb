# frozen_string_literal: true

require 'http'
require 'json'
require 'securerandom'
require_relative 'db'

class Tectonic < Roda
  # The permission to read a lifter's own measurements from Withings. #472.
  #
  # Over the `http` gem, which is already a dependency, rather than through `oauth2` or the
  # `withings-api` gem. #472 warns off the latter -- it targets OAuth 1.0, which Withings
  # disabled in 2018 -- and recommends `oauth2`, which this deliberately does not take, on
  # Mailer's argument about Resend: the whole of the protocol here is two POSTs to one host,
  # and a gem to make two POSTs is more moving parts than the feature has.
  #
  # ## Unconfigured is not an error
  #
  # No client id means development, the suite, and any checkout that has never connected
  # anything. `configured?` is false, the settings page says so plainly, and nothing raises.
  # That is Mailer's rule and it is what keeps the app walkable without a credential.
  #
  # ## Withings' own peculiarities, which are not guessable
  #
  # **Every call is a POST with an `action` parameter**, including the ones any other API
  # would make a GET. The path says which service, the body says which method.
  #
  # **Errors arrive as HTTP 200.** The body carries `status: 0` for success and a non-zero
  # code otherwise, so a response that succeeded at the transport layer can still be a
  # refusal. Anything that checks only the status line will treat "invalid token" as data.
  module Withings
    AUTHORIZE = 'https://account.withings.com/oauth2_user/authorize2'
    # The API host, from the environment rather than hard-coded, because the value is not a
    # secret and Withings publishes more than one. Defaulted so a checkout without a .env
    # still has something coherent to report.
    def self.endpoint = ENV.fetch('WITHINGS_API_ENDPOINT', 'https://wbsapi.withings.net')

    TOKEN_PATH = '/v2/oauth2'
    # What #472 settled: metrics for weight and body composition, activity for sleep and
    # workouts. Deliberately *not* `user.info`, which requires a contract with Withings and
    # fails the whole authorisation without one.
    SCOPES = 'user.metrics,user.activity'
    # On the request path, so a slow provider must not hold a Puma thread open behind
    # somebody's settings page. Mailer's ten seconds, for the same reason.
    TIMEOUT = 10
    # Refresh this far before the token actually dies, so a call that takes a moment to make
    # cannot be issued with a token that expires mid-flight.
    EARLY = 60

    module_function

    def client_id = ENV.fetch('WITHINGS_CLIENT_ID', nil).to_s
    def secret = ENV.fetch('WITHINGS_SECRET', nil).to_s
    def configured? = !client_id.empty? && !secret.empty?

    # Where to send somebody to say yes. `state` is not decoration: it is the only thing
    # tying the callback to the browser that started the flow, and without it anybody can
    # hand this account a code of their own choosing.
    def authorize_url(redirect_uri, state)
      query = { response_type: 'code', client_id:, scope: SCOPES, redirect_uri:, state: }
      "#{AUTHORIZE}?#{URI.encode_www_form(query)}"
    end

    def new_state = SecureRandom.urlsafe_base64(32)

    # The code the callback was handed, exchanged for a pair of tokens. Returns the parsed
    # body or nil -- never raises into a request, on Mailer's argument: a provider having a
    # bad afternoon must not become a 500 on a page the lifter was only visiting.
    def exchange(code, redirect_uri)
      post(TOKEN_PATH, action: 'requesttoken', grant_type: 'authorization_code',
                       client_id:, client_secret: secret, code:, redirect_uri:)
    end

    def refresh(refresh_token)
      post(TOKEN_PATH, action: 'requesttoken', grant_type: 'refresh_token',
                       client_id:, client_secret: secret, refresh_token:)
    end

    # One POST, and the two ways it can fail folded into one nil.
    #
    # The `status` check is the half that is easy to miss: Withings answers 200 with a
    # non-zero status for an expired token, a bad secret and a revoked grant alike, so a
    # caller trusting the HTTP status would store the error body as though it were tokens.
    def post(path, **form)
      response = HTTP.timeout(TIMEOUT).post("#{endpoint}#{path}", form:)
      return report("HTTP #{response.status}", path) unless response.status.success?

      answered(JSON.parse(response.body.to_s), path)
    rescue HTTP::Error, JSON::ParserError => e
      report(e.message, path)
    end

    # The half that is easy to miss, kept on its own so it is hard to: Withings answers 200
    # with a non-zero `status` for an expired token, a bad secret and a revoked grant alike.
    def answered(body, path)
      return body['body'] if body['status'].to_i.zero?

      report("status #{body['status']}: #{body['error']}", path)
    end

    # Logged and reported rather than raised, and returning nil, which is the answer every
    # caller here is written to handle. A failure to reach Withings is not something the
    # lifter did wrong and must not reach them as a 500.
    #
    # Mailer's shape, down to guarding on Sentry being initialised: the suite and a local
    # checkout have no DSN, and a module that assumed one would make every offline test a
    # network call.
    def report(reason, path)
      warn "[withings] #{path} failed: #{reason}"
      ::Sentry.capture_message("Withings #{path} failed: #{reason}") if defined?(::Sentry) && ::Sentry.initialized?
      nil
    end
  end
end

