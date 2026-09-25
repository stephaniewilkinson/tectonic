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
    # And where sleep answers, which is neither of them. #579.
    #
    # Both `Sleep v2 - Get` and `Sleep v2 - Getsummary` are here, told apart by `action` the
    # way everything else in this API is. Worth one line of warning for the next reader of the
    # reference: the OpenAPI document keys operations by URL, so having two on one path it
    # publishes the second as `"https://wbsapi.withings.net/v2/sleep "` -- with a trailing
    # space, to make the key unique. The space is in their own PHP and curl samples too. It is
    # a quirk of how the document is assembled and not part of the path.
    SLEEP_PATH = '/v2/sleep'
    # What `getsummary` must be asked for by name, and the trap is `WORKOUT_FIELDS`' trap in
    # another place: every field under a summary's `data` is documented *"(Use 'data_fields' to
    # request this data.)"*, so a request without this comes back with a night in it and
    # nothing inside the night -- no error, no empty keys, and a caller reading a missing
    # figure as a lifter who did not sleep.
    #
    # One field, deliberately. The stage split, the efficiency ratio and everything in the
    # Total biomarker pack are each refused for their own reason; `WithingsSleep`'s comment
    # is where those reasons are, because they are decisions about what this app will say
    # rather than facts about the API.
    #
    # What is *not* here and arrives anyway is the pair that matters most: `startdate` and
    # `enddate` are on the summary object itself rather than under `data`, so the two ends of
    # the night cost no parameter at all.
    SLEEP_FIELDS = 'total_sleep_time'
    # What `getworkouts` must be asked for by name.
    #
    # This is the part of the endpoint that is not guessable from its documentation. Without
    # `data_fields` the answer carries ids, category and timestamps and *nothing else* -- no
    # error, no empty keys, simply an activity with no measurements in it. A caller that
    # assumed the heart rate would be there would find nil on every row and have no way to
    # tell that from a watch that recorded none.
    #
    # **`effduration` was in this list and is not a field Withings has.** #586. The whole
    # OpenAPI document their reference renders -- a string literal inside
    # `developer.withings.com/assets/js/main.<hash>.js`, the hash taken from the `<script
    # src=>` of `/api-reference/`, which is the only way to read the reference as text at all
    # -- has zero occurrences of the name: not in the `data_fields` list for `getworkouts`,
    # not in the `workout_object` schema the response is made of, nowhere in 1.5 MB. Read off
    # bundle `main.8ae1c0ad.js` on 2026-09-24. The only duration-shaped fields for an activity
    # are `pause_duration` and `algo_pause_duration`; the `*duration` names that do exist
    # elsewhere -- `asleepduration`, `lightsleepduration` -- belong to sleep.
    #
    # The data said the same thing for a year and nobody could read it: `effective_seconds`
    # is null on every row this app has ever stored. Asking cost nothing on the wire, which is
    # exactly why it survived -- Withings drops a name it does not recognise instead of
    # refusing the request, so a retired or misremembered field is indistinguishable from a
    # live one that this watch never fills. What it did cost is a reader's fair assumption
    # that every name here is live, a column that could never be filled, and #571 an argument
    # built on an absence: two activities "came back with no `effduration`", read as the
    # signature of a workout the watch detected rather than one somebody started. They came
    # back without it because nobody could have got it. See app.rb and views/workouts/show.erb,
    # where that inference is now corrected rather than deleted.
    #
    # The other four were checked against that same document in the same sitting and are all
    # published for this action, in both the `data_fields` list and `workout_object.data`, and
    # all four are marked available for every category except Multi-sport and breathing
    # exercises -- category 16, "Lift weights", is in scope for each. The list stays shorter
    # than what is on offer on purpose: `hr_zone_0` through `hr_zone_3`, `steps`, `distance`,
    # `spo2_average` and `core_body_temperature_*` are all there for the asking, and each one
    # would want a column, a reader and a reason before it is worth a parameter.
    WORKOUT_FIELDS = 'calories,hr_average,hr_min,hr_max'
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
    # `pause` is seconds to wait before asking for the *next* page, and it is nought here
    # because the caller this was written for is a page view that wants one window and
    # usually one page. A backfill is the other caller and passes a real number: a walk over
    # a decade is a few hundred of these in a row, and Withings ask not to be polled more
    # than once every ten minutes per user while the commonly cited application ceiling is
    # 120 requests a minute. A serial walk with a second between pages is nowhere near
    # either; the same walk with no pause at all is a tight loop against somebody else's
    # service, and the way that ends is status 601 -- which arrives as HTTP 200 and is
    # indistinguishable, by the time it reaches a caller, from an afternoon with nothing in
    # it. Cheaper to wait than to be unable to tell.
    #
    # Nothing sleeps before the first page or after the last: the pause belongs between two
    # requests, and a run of one request should cost what one request costs.
    # A ceiling on the pages one window will follow, for the reason WithingsMeasures gives for
    # its own: `more` is a loop condition a provider controls, and a loop a provider controls
    # needs a bound that we control. Far above any real year -- Withings pages workouts in the
    # hundreds and nobody trains that often.
    #
    # Exhausting it returns nil rather than what arrived, which is the same answer this method
    # gives for any other failure to be told the whole window. A short list would be read as
    # the complete one -- the backfill would stamp a year it had not finished, and a record
    # page would offer a candidate from a set that was never fully looked at.
    MAX_PAGES = 20

    def workouts(token, from:, to:, pause: 0)
      gathered = []
      offset = 0
      MAX_PAGES.times do
        body = workout_page(token, from, to, offset)
        return nil unless body

        gathered.concat(Array(body['series']))
        return gathered unless more?(body)

        offset = paused(body, pause)
      end
      report("more than #{MAX_PAGES} pages", MEASURE_V2_PATH)
    end

    # Where the next page starts, after the wait that belongs between two requests. The two
    # are one step rather than two lines because the pause is part of asking for the next
    # page, not a thing done on its own.
    def paused(body, pause)
      sleep pause if pause.positive?
      body['offset'].to_i
    end

    # Whether Withings says there is another page.
    #
    # **`0` is truthy in Ruby**, which is the whole reason this is a method rather than the
    # bare `body['more']` that stood here. Withings documents `more` as a number and has been
    # observed returning a boolean, so a quiet year answering `more: 0` read as "there is
    # more", the offset it came with was `0`, and the loop asked for the same page until
    # something killed it -- a pinned Puma thread on a record page, or a rake task in a tight
    # loop against somebody else's service.
    #
    # WithingsMeasures worked this out first and wrote its own copy. Two copies of one
    # provider quirk is how they came to disagree, so there is one now and the other defers
    # to it.
    # Every shape it has been seen in, rather than the two somebody remembered. A number is
    # a count and `0` means no; a boolean means itself; absent means no. Writing this as
    # `flag == true || flag.to_i.positive?` -- which is what stood in WithingsMeasures --
    # raises on a literal `false`, because `false` has no `to_i`. That never fired only
    # because the two callers had each been fed a different half of the possibilities.
    def more?(body)
      flag = body['more']
      case flag
      when Numeric then flag.positive?
      when String then flag.to_i.positive?
      else flag ? true : false
      end
    end

    def workout_page(token, from, to, offset)
      post(MEASURE_V2_PATH, token:, action: 'getworkouts', data_fields: WORKOUT_FIELDS,
                            startdateymd: from.strftime('%Y-%m-%d'),
                            enddateymd: to.strftime('%Y-%m-%d'), offset:)
    end

    # The watch's heart rate, reading by reading, between two instants. #656.
    #
    # `getintradayactivity` on the measure v2 path, which takes unix seconds rather than the
    # civil dates `getworkouts` wants, and answers one window of at most a day with no paging:
    # `series` is keyed by the reading's own unix time. #579 probed it twice before a line of
    # this was written -- every ten minutes outside a workout the watch knows about, every
    # fifteen seconds or faster inside one -- which is why a caller asks for a session's own
    # window and says how much of it came back, rather than assuming.
    def intraday_heart_rate(token, from:, to:)
      post(MEASURE_V2_PATH, token:, action: 'getintradayactivity', data_fields: 'heart_rate',
                            startdate: from.to_i, enddate: to.to_i)
    end

    # One page of a range of nights, as summaries. #579.
    #
    # Civil dates like `getworkouts` and unlike `getmeas`, and the same mutually-exclusive
    # trap: the published spec marks `startdateymd`, `enddateymd` *and* `lastupdate` all
    # required, and sending the third alongside the first two is refused. Only the pair is
    # sent, because `lastupdate` is a resume cursor and the caller here does not resume -- see
    # `WithingsSleep.window` for why its range is a constant.
    #
    # **Seven days is the most one call may span.** The reference says so on the summary
    # object's own `enddate`: *"A single call can span up to 7 days maximum. To cover a wider
    # time range, you will need to perform multiple calls."* It is not enforced here, because
    # the caller's window is narrower than it by construction and a second opinion about
    # somebody else's limit is a second place for it to be wrong.
    #
    # Paged like everything else, and `offset` is only sent once there is one, so the first
    # request of a window carries no cursor at all.
    def sleep_summaries(token, from:, to:, offset: nil)
      form = { action: 'getsummary', data_fields: SLEEP_FIELDS,
               startdateymd: from.strftime('%Y-%m-%d'), enddateymd: to.strftime('%Y-%m-%d') }
      form[:offset] = offset if offset
      post(SLEEP_PATH, token:, **form)
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

