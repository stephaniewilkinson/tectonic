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
    # Where the measurements are. Withings splits the API by path and then by `action`, so
    # this names the service and `getmeas` names the method on it. #518.
    MEASURE_PATH = '/measure'
    # And where the *other* measure service is, which is not the same host path and is the
    # one trap in this module that a reader would never guess. Withings kept both: `getmeas`
    # answers on `/measure` and `getworkouts` answers on `/v2/measure`, and each refuses the
    # other's path. Two constants rather than one, because #518 and #520 each found the path
    # their own action needed and a single name would have to be wrong for one of them.
    MEASURE_V2_PATH = '/v2/measure'
    # What `getworkouts` must be asked for by name.
    #
    # This is the part of the endpoint that is not guessable from its documentation. Without
    # `data_fields` the answer carries ids, category and timestamps and *nothing else* -- no
    # error, no empty keys, simply an activity with no measurements in it. A caller that
    # assumed the heart rate would be there would find nil on every row and have no way to
    # tell that from a watch that recorded none.
    WORKOUT_FIELDS = 'calories,effduration,hr_average,hr_min,hr_max'
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

    # Every activity the watch recorded across a range of civil days, oldest page first. #520.
    #
    # `startdateymd`/`enddateymd` rather than the epoch pair the rest of this module deals
    # in, because that is what this action takes: civil dates, `Y-m-d`, and the answer comes
    # back with epochs in it. The published spec marks `startdateymd`, `enddateymd` *and*
    # `lastupdate` all required; they are in fact mutually exclusive, and sending the third
    # alongside the first two is refused. Only the date pair is sent here -- `lastupdate` is
    # the resume cursor a poller would want, and nothing here polls.
    #
    # **Paged, and the loop is not optional.** Withings answers a window wider than one page
    # with `more: true` and an `offset` to send back, and a caller that read the first page
    # and stopped would silently lose every activity after the twentieth-odd. Worse, it
    # would lose them at exactly the moment a lifter had had a busy fortnight.
    #
    # Nil for a failure of any page rather than the pages gathered so far, and that nil is
    # load-bearing: `answered` folds Withings' rate-limit status (601) into the same nil as a
    # revoked token, so a throttled fetch is indistinguishable from an empty one at this
    # level. Returning a short array would make it *look* like an answer, and a caller would
    # render "no activity" about a request that was never served. An empty array means
    # Withings said there was nothing; nil means Withings did not say.
    def workouts(token, from:, to:)
      gathered = []
      offset = 0
      loop do
        body = workout_page(token, from, to, offset)
        return nil unless body

        gathered.concat(Array(body['series']))
        return gathered unless body['more']

        offset = body['offset'].to_i
      end
    end

    def workout_page(token, from, to, offset)
      post(MEASURE_V2_PATH, token:, action: 'getworkouts', data_fields: WORKOUT_FIELDS,
                            startdateymd: from.strftime('%Y-%m-%d'),
                            enddateymd: to.strftime('%Y-%m-%d'), offset:)
    end

    # A window of measurements, which is the one thing this app reads. #518.
    #
    # Every parameter is Withings' own and none of them is guessable. `meastypes` is a
    # comma-separated list of their numeric type codes. The dates are unix seconds. `category`
    # is 1 for readings that actually happened -- the same endpoint returns the *goals* a
    # lifter has set for themselves under category 2, and taking the default would file a
    # target bodyweight as though somebody had stood on a scale and weighed it.
    #
    # `offset` is their pagination cursor, handed back by a response that says `more`. A
    # window wide enough to be worth asking for is wider than one page, so a caller that
    # ignored it would keep the newest readings and silently drop the rest of the window --
    # see WithingsMeasures.pages, which is what follows it.
    def measures(token, meastypes:, startdate:, enddate:, offset: nil)
      form = { action: 'getmeas', meastypes:, category: 1,
               startdate: startdate.to_i, enddate: enddate.to_i }
      form[:offset] = offset if offset
      post(MEASURE_PATH, token:, **form)
    end

    # One POST, and the two ways it can fail folded into one nil.
    #
    # The `status` check is the half that is easy to miss: Withings answers 200 with a
    # non-zero status for an expired token, a bad secret and a revoked grant alike, so a
    # caller trusting the HTTP status would store the error body as though it were tokens.
    #
    # `token` is a keyword rather than one more form field because the two halves of this API
    # disagree about where the credential goes. The token endpoint authenticates with the
    # client secret in the body and takes no header; every other call wants
    # `Authorization: Bearer` and ignores an `access_token` parameter, which was the shape of
    # the API Withings retired. Sending it the old way does not fail loudly -- it comes back
    # as a non-zero status meaning "invalid token", which is indistinguishable here from a
    # revoked grant, so the app would tell a lifter to reconnect a connection that was fine.
    def post(path, token: nil, **form)
      request = HTTP.timeout(TIMEOUT)
      request = request.auth("Bearer #{token}") if token
      response = request.post("#{endpoint}#{path}", form:)
      return report("HTTP #{response.status}", path) unless response.status.success?

      answered(JSON.parse(response.body.to_s), path)
    rescue HTTP::Error, JSON::ParserError => e
      report(e.message, path)
    end

    # The half that is easy to miss, kept on its own so it is hard to: Withings answers 200
    # with a non-zero `status` for an expired token, a bad secret and a revoked grant alike.
    #
    # **And for being asked too often.** Status 601 is "Too many request", and it arrives by
    # the same route as everything else, so the nil this returns covers a credential that is
    # dead and a call that should simply be made again later. Nothing downstream can tell
    # them apart, which is why no caller here may turn a nil into "your connection needs
    # renewing" -- see WithingsMeasures, which reports a failed fetch as unreachable and
    # keeps "needs renewing" for the one case that really does say so, a refresh that failed.
    # Carrying the code out to callers would widen this return contract for the token
    # exchange too, so it is deliberately not done here; the code is in the log and in Sentry.
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

