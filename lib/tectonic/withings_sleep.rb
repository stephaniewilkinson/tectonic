# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require_relative 'db'
require_relative 'withings'
require_relative 'withings_connection'
require_relative 'withings_measures'

class Tectonic < Roda
  # How long the lifter slept the night before a session, brought into `health_metrics`. #579.
  #
  # #579 surveyed everything Withings has that a barbell app might want and found most of it
  # behind a paid biomarker plan, behind a watch this account may not wear, or a verdict
  # wearing a measurement's clothes. One candidate survived on its own merits: *"You slept
  # 6h10 before this session"* is a fact, it is measured, the scope is already granted, it is
  # in the Basic pack, and a ScanWatch produces it with no sleep mat anywhere. This is that,
  # and deliberately only that.
  #
  # ## What this refuses to say
  #
  # There is no threshold, no score, no band of "enough", and nothing anywhere that reads a
  # short night as a reason to do less. #263 settled that split and bodyweight already obeys
  # it: the app reports the hours and the assistant reading them decides what they mean. It
  # matters more here than it did for a training max, because sleep is the number a person is
  # most likely to have already decided how to feel about, and because a readiness score is
  # the single easiest thing to bolt onto a duration and the hardest to take off again.
  #
  # ## A night is a span and `measured_at` is an instant
  #
  # This is the design question #579 raised and could not settle from the outside, and the
  # reference settles it: **both ends of the night arrive on every summary**, as `startdate`
  # and `enddate`, at the top level of the object where they cost no `data_fields` and no
  # extra request. #579's cost table put it as a choice -- file at wake time and keep the join
  # to the next morning's session, or file at bed time and keep the bed time -- and the choice
  # is a false one.
  #
  # So: **the row is filed at the waking end, and the width of the night is a second row.**
  #
  # The waking end, because that is the end a session is read against. The question a lifter
  # actually asks is "did I sleep badly before that session", the session's own start is known
  # from its first completed set, and the night that answers it is the one whose *wake time*
  # is the last one before that start. Filing at bed time would put a night that ended at 07:05
  # under a timestamp of 23:35 the previous day, and every reader would have to know the app's
  # idea of how long a night is before it could tell last night from the one before.
  #
  # And the width as its own row, because a night's span does not need a second timestamp to
  # survive -- it is a duration, and a duration is a measurement. `sleep_window_hours` beside
  # `sleep_hours` at one instant is the shape 041 already built for and `BodyReadings.weigh_ins`
  # already reads: several metrics from one event, separate rows, joined by `measured_at`. Bed
  # time is the wake time less the window, exactly, with nothing inferred.
  #
  # Which leaves the two rows saying different and necessary things. 6h10 of sleep inside a
  # 6h30 window and 6h10 inside a nine-hour one are different nights, and only the first of
  # them supports any reading about a short night at all. That is #571's lesson in its sleep
  # shape: the honest hedge on a figure from a wearable is about *coverage* -- what the device
  # was listening over -- rather than about precision, and a duration reported without its
  # window invites a reader to assume the two are the same number.
  #
  # If the two ends of a night ever need to be queried as ends rather than reconstructed, that
  # is a table and not a column, and it should be decided then. 042 made that argument for
  # workouts and it is the same argument; what it is not is a reason to pre-empt it here.
  #
  # ## Hours, which is the one place this departs from "store what Withings sent"
  #
  # `WithingsMeasures` stores kilograms because kilograms are what the lifter's own scale
  # showed them, and converting on the way in produces a number they never saw. That argument
  # is about a unit somebody *chose*. Seconds are not that: nobody's watch reports a night in
  # seconds, no Withings screen shows one, and the field is seconds because JSON has to carry a
  # duration somehow. Hours is what a night is said in, by the lifter and by Health Mate alike.
  #
  # The conversion is done in BigDecimal rather than by floating point, for 041's reason and
  # #518's: `22200 / 3600.0` is 6.166666666666667 and a Float rounded on the way in is a Float
  # somebody later reads as exact. The column is numeric(10,3), so the stored figure resolves
  # to 3.6 seconds -- which is below anything a wrist device can claim about a night, and is
  # the only rounding anywhere in this file.
  #
  # ## What is deliberately not asked for
  #
  # **The stage split** -- light, deep and REM -- is in the Basic pack and a ScanWatch does
  # produce it. It is left out on #579 Part 6's argument: a wrist device's stage split is
  # weakly validated against polysomnography, so it is a model's output wearing a
  # measurement's clothes, and the repo's answer to that (#472's bands, `day_to_day`) does not
  # fit it. That machinery measures how much a number moves from one reading to the next,
  # which is a noise estimate; what is wrong with a wrist stage split is bias, and a band
  # around a biased figure makes it look better rather than worse. Total sleep time is the
  # sturdy figure and is the one asked for.
  #
  # **`sleep_efficiency`**, being a ratio of two estimates, and -- the part #579 got wrong --
  # not promised on a tracker at all: Withings' availability table lists it under the sleep
  # mats and not in the tracker column. Same for `sleep_latency`, `wakeup_latency`, `waso`,
  # `nb_rem_episodes` and `out_of_bed_count`. Asking for a field that is not promised is
  # asking for the failure this integration keeps running into -- an absent field that cannot
  # be told from an instrument that recorded nothing.
  #
  # **Everything in the Total pack**: `sleep_score`, overnight HRV, snoring, respiration, AHI.
  # #579 declines the lot, on the grounds that an unentitled field comes back absent rather
  # than refused, and a value that cannot be told from silence is worse than no value.
  #
  # ## The window, and the week that is not read
  #
  # Withings' reference says of the summary object's `enddate`, verbatim: *"A single call can
  # span up to 7 days maximum. To cover a wider time range, you will need to perform multiple
  # calls."* So seven days is the widest one request may be, and this asks for exactly that,
  # every time, ending today.
  #
  # Which makes the window a constant rather than something derived from a watermark, and that
  # is the whole of why `sleep_read_at` is not a resume cursor -- see 052. It also means an
  # account nobody reads for longer than a week has nights that were never asked about and
  # never will be. That is a real hole, it is stated rather than papered over, and closing it
  # is a walk backwards with its own reach column, which is a separate piece of work. It is
  # not this one: a walk over a year of nights is fifty-two requests, and this runs on the
  # request path inside a twenty-second budget.
  #
  # ## What a caller is told, and what it must not conclude
  #
  # The same six outcomes as a measurement fetch, on the same struct, deliberately. Every
  # failure Withings has arrives as nil -- a dead grant, a bad secret, and status 601 "too many
  # request", all of them 200s that `Withings.answered` folds together -- so a read that came
  # back with nothing cannot say why, and in particular **a failed read may never render as
  # "you did not sleep"**. That is the distinction `:incomplete` and `:unreachable` exist to
  # carry, and inventing a seventh outcome for sleep would only give two modules two
  # vocabularies for one set of facts. `Withings.more?` is in this file's history as a warning
  # about exactly that: two copies of one provider quirk is how they came to disagree.
  module WithingsSleep
    # The same source as the weigh-ins, because it is the same provider and the same grant.
    # A reader that wanted to tell a watch's rows from a scale's tells them apart by the
    # metric, which is what the metric names are for.
    SOURCE = 'withings'

    # How much of the night was sleep, and how wide the night the device recorded was.
    #
    # `sleep_window_hours` and not `time_in_bed`. Withings have a `total_timeinbed` field and
    # this is not it: that one is a sleep mat's metric, it is absent from the tracker column of
    # their own availability table, and it is not asked for here. This is the distance between
    # the two timestamps on the summary -- the span the device recorded the night over -- and
    # naming it after the mat's field would be claiming a measurement nobody took.
    SLEPT = 'sleep_hours'
    WINDOW = 'sleep_window_hours'

    # The names this module writes, which is also the list `HealthReadings` reads to decide
    # which instrument a question is about. One list, so a metric added here is a metric that
    # triggers the right fetch without anybody remembering to say so twice.
    METRICS = [SLEPT, WINDOW].freeze

    # Stored as given by nobody -- see the file comment. `h` rather than `hours` because it is
    # printed beside a number in a sentence, and the existing units in this table are `kg` and
    # `%`.
    UNIT = 'h'
    SECONDS_PER_HOUR = 3600
    # Three, because that is what numeric(10,3) carries and rounding further on the way in
    # would be throwing away resolution the column has room for.
    PLACES = 3

    # How many civil days one request asks for, which is Withings' own maximum for this
    # action and not a number chosen here. Seven days inclusive is `today - 6` through
    # `today`.
    SPAN_DAYS = 7

    # How stale the last read has to be before another is made. `WithingsMeasures::STALE_AFTER`'s
    # value and its whole argument: Withings ask not to be polled more than once every ten
    # minutes per user, this sits above that with room to spare, and it is short enough that a
    # lifter who asks after a night's sleep has arrived gets it on the second ask rather than
    # tomorrow. Written out rather than referenced, because the two floors are independent
    # rate limits on two different requests and a shared constant would make changing one
    # change the other by accident.
    STALE_AFTER = 15 * 60

    # A ceiling on the pages one read will follow, for the reason `WithingsMeasures` gives for
    # its own: `more` is a loop condition a provider controls, and a loop a provider controls
    # needs a bound that we control. Far above any real week -- seven nights is seven objects
    # and Withings page in the hundreds, so in practice `more` never fires here at all.
    MAX_PAGES = 20

    # One struct, not two. `WithingsMeasures::Fetch` is not a fact about weigh-ins: it is what
    # a read of Withings did, in the six shapes a read of Withings can end in, and every one
    # of them means here what it means there. A second copy carrying the same six symbols is
    # how two modules come to disagree about what `:incomplete` includes, which is the mistake
    # `Withings.more?` was written to undo.
    #
    # Its third member is `read_at` rather than `synced_at` precisely so that this module can
    # use it without the borrowed name making a claim about the measurement poll's column.
    Fetch = WithingsMeasures::Fetch

    module_function

    # The entry point for anything about to read sleep: bring it up to date if it is not, and
    # otherwise do nothing at all. `HealthReadings` is the only caller, through
    # `MCP::Tools::Freshness`, and it calls this only when the metric asked about is one of
    # `METRICS` -- a question about bodyweight cannot be answered differently by anything the
    # watch says, so a read spent there is a read closer to the one refusal this integration
    # cannot tell apart from a dead connection.
    #
    # Cheap in the ordinary case: one indexed row by account id, and no network.
    def freshen(account_id, now: Time.now)
      row = WithingsConnection.of(account_id)
      return Fetch.new(:absent, 0, nil) unless row
      return Fetch.new(:fresh, 0, row[:sleep_read_at]) if fresh?(row[:sleep_read_at], now)

      fetch(account_id, now:)
    end

    def fresh?(read_at, now) = !read_at.nil? && read_at > now - STALE_AFTER

    # The read itself, with no staleness check in front of it, so that a task run by hand has
    # something to call that means "now, regardless".
    #
    # Not guarded on `Withings.configured?`, for `WithingsMeasures.fetch`'s reason: an access
    # token already in hand works without the client credentials, which are needed to refresh
    # it rather than to spend it.
    def fetch(account_id, now: Time.now)
      row = WithingsConnection.of(account_id)
      return Fetch.new(:absent, 0, nil) unless row

      token = WithingsConnection.token(account_id)
      return Fetch.new(:revoked, 0, row[:sleep_read_at]) unless token

      collect(account_id, token, row, now)
    end

    # The window, its pages, the rows, and the watermark -- the last of them only if every
    # page arrived.
    #
    # Nothing is stamped on a read that stopped partway. The nights that did arrive are stored
    # either way, because they are real and because the unique index makes storing them again
    # free; what a truncated read may not do is say the week has been read, since the missing
    # page is a night that nothing will ever ask for again. `:incomplete` is how that is
    # reported instead of hidden.
    #
    # The write is one transaction with the stamp it is a claim about, so a process killed
    # between the two cannot leave a watermark outliving the nights it says were fetched.
    def collect(account_id, token, row, now)
      nights, whole = pages(token, *window(now))
      return Fetch.new(:unreachable, 0, row[:sleep_read_at]) if nights.nil?

      stored = DB.transaction do
        written = nights.sum { |night| store_night(account_id, night) }
        DB[:account_withings].where(account_id:).update(sleep_read_at: now) if whole
        written
      end
      Fetch.new(whole ? :stored : :incomplete, stored, whole ? now : row[:sleep_read_at])
    end

    # The seven civil days ending today, which is the widest a single call may be.
    #
    # Civil days rather than instants because that is what this action takes -- `startdateymd`
    # and `enddateymd`, `Y-m-d` -- and the answer comes back with epochs in it, the same shape
    # `getworkouts` has. The published spec marks `startdateymd`, `enddateymd` *and*
    # `lastupdate` all required and they are in fact mutually exclusive; only the date pair is
    # sent, for the reason `Withings.workouts` already gives.
    #
    # The server's day rather than the lifter's, which is worth one sentence because the rest
    # of the app is careful about the difference (#349). It does not matter here: the window
    # is seven days wide and re-read on every stale call, so a boundary an hour either side of
    # a lifter's midnight is inside it on this read or on the next one, and a night filed at a
    # wake time is not a night filed on a date at all.
    def window(now)
      today = now.to_date
      [today - (SPAN_DAYS - 1), today]
    end

    # Every page of the window, and whether that really was every page.
    #
    # Nil for the nights only where the *first* page failed, because then there is nothing to
    # be partially right about. A later page failing returns what did arrive and false, and
    # `collect` is what refuses to call that a complete week. The distinction is the one
    # `Withings.answered` makes unavoidable: an empty `series` means Withings said there was
    # nothing, and nil means Withings did not say.
    def pages(token, from, to)
      nights = []
      offset = nil
      MAX_PAGES.times do
        body = Withings.sleep_summaries(token, from:, to:, offset:)
        return [nights.empty? ? nil : nights, false] unless body

        nights.concat(body['series'] || [])
        return [nights, true] unless Withings.more?(body)

        offset = body['offset']
      end
      [nights, false]
    end

    # One night: its two rows, or the one of them that was actually reported, or none.
    #
    # Three refusals, and each is the same refusal in a different place -- never write a row
    # this app is guessing at.
    #
    # **No `enddate`, no row at all.** The waking end is the instant every row here is filed
    # at, and a night with nowhere to file it cannot be joined to anything.
    #
    # **No `id`, no row at all.** The summary's own id is the whole of what makes a second read
    # of the same week a no-op rather than a second copy of it, and a night without one would
    # be stored again on every read until the table was a trend drawn seven times.
    #
    # **No `total_sleep_time`, no sleep row** -- and emphatically not a zero. #579's central
    # finding is that a field the plan or the device does not entitle us to comes back absent,
    # indistinguishable from an instrument that recorded nothing, and the one thing neither of
    # those means is that the lifter did not sleep. The window row still goes in: the device
    # did record a night between two instants, and that is a fact whatever it says about what
    # happened inside it.
    def store_night(account_id, night)
      woke = night['enddate']
      return 0 unless woke && night['id']

      at = Time.at(woke.to_i)
      values(night, woke.to_i).sum { |metric, seconds| write(account_id, night, at, metric, seconds) }
    end

    # What one night is worth storing, as metric => seconds, before any of it is a row.
    #
    # The window is the distance between the two timestamps, and is skipped where they do not
    # describe a span -- a night with no `startdate`, or one whose ends are the same instant or
    # the wrong way round, has no width to report and a zero there would read as a night with
    # no length.
    def values(night, woke)
      slept = night.dig('data', 'total_sleep_time')
      went = night['startdate']&.to_i
      found = {}
      found[SLEPT] = slept.to_i if slept
      found[WINDOW] = woke - went if went && woke > went
      found
    end

    # Returns 1 for a row that was new and 0 for one already held, so the count a caller gets
    # is what this read added rather than what the week contained. Sequel's `insert` under ON
    # CONFLICT DO NOTHING answers nil when nothing was written, which is the whole check.
    #
    # Do-nothing rather than an upsert, which is `WithingsWeighIn.store_measure`'s choice and
    # is made here for its reason and one more of its own. A count that meant "rows written"
    # would be a count that said nothing about whether anything arrived, and the freshness note
    # a reader is given is built from it. The cost is that a night Withings later re-analyses
    # keeps the figure it was first stored with; that is a known limit rather than an oversight,
    # and picking up a revision means reading `modified` and deciding what a corrected
    # measurement is, which is its own piece of work.
    def write(account_id, night, at, metric, seconds)
      written = DB[:health_metrics]
                .insert_conflict(target: %i[source external_id])
                .insert(account_id:, metric:, unit: UNIT, measured_at: at, source: SOURCE,
                        value: hours(seconds), external_id: external_id(account_id, night, metric))
      written ? 1 : 0
    end

    # Seconds as hours, exactly as far as the column goes and no further. BigDecimal rather
    # than Float throughout: `22200 / 3600.0` is 6.166666666666667, Postgres would round it
    # back to three places today, and the day the column widens is the day that becomes a
    # number somebody reads as exact.
    def hours(seconds) = (BigDecimal(seconds.to_i) / SECONDS_PER_HOUR).round(PLACES)

    # The source's id for one row, scoped to the account and to the service that produced it.
    #
    # The account id is in front for `WithingsWeighIn.external_id`'s reason: the unique index
    # is on `[source, external_id]` across the whole table rather than per account, so a bare
    # id would mean one account's stored night silently swallowing another's -- which is what
    # somebody with a second account connected to one Withings login does on purpose.
    #
    # And `sleep` is in the middle because a sleep summary's `id` and a measure group's `grpid`
    # are **different id spaces from the same provider under the same `source`**. Nothing says
    # they cannot collide, and the symptom of a collision is not an error: it is a night, or a
    # weigh-in, that simply never arrives, because the insert conflicts and does nothing.
    def external_id(account_id, night, metric) = "#{account_id}:sleep:#{night['id']}:#{metric}"
  end
end

