# frozen_string_literal: true

require 'bigdecimal'
require_relative 'db'
require_relative 'withings'
require_relative 'withings_connection'

class Tectonic < Roda
  # What the scale recorded, brought into `health_metrics`. #518.
  #
  # The connection (#517) was permission and nothing read through it. This is the read: one
  # call to Withings' `Measure - Getmeas`, a window of weigh-ins, and a row per number on each
  # of them. Nothing here judges any of it -- a body fat percentage is stored exactly as the
  # instrument reported it, and what it is worth is #519's problem and then the reader's.
  #
  # ## Nothing happens unless somebody asks
  #
  # #472's research says to poll daily rather than take webhooks, and that reasoning stands --
  # a weigh-in arriving six hours late costs nothing, and polling avoids standing up a public
  # endpoint to secure. What it does not settle is what does the polling, and the answer
  # changed when #458 declined to generate weeks unasked: a scheduled job needs a second paid
  # service on Render, which is the infrastructure that decision refused.
  #
  # So the trigger is `freshen`, called by whatever is about to read the numbers, and it makes
  # a call only if the last one is old enough to be worth another. The measurements are
  # current exactly when somebody is looking at them and at no other time, which is both
  # cheaper and the same rule the rest of the app follows. #518 lists this as its open
  # question and recommends this answer; #533 wired it up, so the callers are the three
  # reading tools and nothing else, and moving the trigger means moving those three.
  #
  # ## What a caller is told, and what it must not conclude
  #
  # Every failure Withings has arrives here as nil -- a dead token, a bad secret, and status
  # 601, "too many request", all of them 200s with a non-zero status that `Withings.answered`
  # folds together. A fetch that came back with nothing therefore cannot say *why*, and in
  # particular it cannot say the grant was revoked. The one thing that does say that is a
  # refresh that failed, which is `WithingsConnection.token` returning nil, and that is the
  # only path here that reports :revoked.
  #
  # ## Two watermarks, because a read has two different things to say about itself
  #
  # `synced_at` means *everything up to here has been read*, and only a window that arrived
  # whole may move it. That is right, and on its own it left a first read with nothing to
  # show for a refusal: the first read reaches back a year, a year is the widest and most
  # expensive request this app makes, and a request refused partway stored its rows and moved
  # nothing -- so the next read asked for the same year, and the one after that. The window
  # never narrowed, and the request likeliest to be throttled was the one retried forever
  # (#557).
  #
  # The second, `measures_read_back_to`, says *how far back* -- which is a different claim and
  # needs a different column, exactly as the backfill keeps its own read range off
  # `synced_at`. Together they describe one stretch of time: from the reach forward to
  # `synced_at`, every reading has been fetched. A read asks for that stretch's near end and
  # then walks backwards behind it, and each piece that arrives whole moves one watermark or
  # the other without either of them claiming anything the other has not earned.
  #
  # What none of it does is stamp `synced_at` on a truncated read. A read that stopped has not
  # read everything up to anywhere, and saying it has would trade a slow loop for readings
  # that go missing with nothing to show it -- which is the failure `:incomplete` exists to
  # report rather than hide.
  #
  # The distinction that matters most is between a fetch that failed and a window that was
  # genuinely empty. Both store nothing. Only one of them means "you have not weighed
  # yourself", and reporting the other that way is the class of lie the schema draws a column
  # to avoid -- so the outcome is on the struct rather than left to be inferred from a count
  # of zero, and `failed?` is there so a reader cannot get it wrong by accident.
  module WithingsMeasures
    SOURCE = 'withings'

    # What a body-composition scale reports, and what each reading is called here.
    #
    # The keys are Withings' measure types, which are numbers and are not guessable from
    # anything; the values are this app's names, and are the ones #519's reading tools will
    # ask for. `lean_mass` is Withings' "fat free mass" under the name #472's schema note
    # gave it -- the same quantity, and renaming it here would leave the two documents
    # describing different columns.
    #
    # All of them come back from one call, so there is no cheaper subset to ask for: a scale
    # that measures body composition measures all of it in one stand.
    #
    # ## 11, and what it is honestly worth
    #
    # **This used to say heart rate was deferred to a later ticket**, with blood pressure,
    # "with the rest of `user.activity`". #579 read Withings' own scope table and found that
    # sentence wrong on both halves: `Measure - Getmeas` is under `user.metrics`, which this
    # account already holds, and type 11 is in the Basic biomarker pack, which is the tier this
    # app is on. There was never a later ticket's worth of work in it. It is one line, it rides
    # the request `MEASTYPES` already builds, and it needs no migration, because 041 made
    # `health_metrics.metric` free text precisely so that a new reading is a line in a hash.
    #
    # **What it will actually yield here is probably nothing, and that is not a reason to leave
    # it out.** Withings' reference says of type 11, in these words, *"Heart Pulse (bpm) - only
    # for BPM and scale devices"* -- it is a pulse the instrument takes while it is taking some
    # other reading, off a blood-pressure monitor's cuff or a scale's footpads. The reporting
    # account has no scale at all; its bodyweights are typed into the Withings app by hand, and
    # a typed weight carries no pulse. So this may well never produce a single row on this
    # account, and nothing downstream may read an empty `standing_hr` as a statement about
    # anybody's heart. It is here because it costs nothing to ask for and starts collecting on
    # its own the day a device that produces it is stood on, which is the whole of the case.
    #
    # **`standing_hr` rather than `resting_hr`**, which is the name the honesty turns on. This
    # is a pulse taken during a measurement -- standing on a scale, or sitting with a cuff on
    # -- and not a resting heart rate in the sense anybody means by that, which is taken lying
    # still and is a different number. It is not a workout heart rate either; those live on
    # `withings_workouts` with the activity they were measured over, and a name that let the
    # two be read together would put a set of squats and a weigh-in in one series.
    #
    # A type this table does not name is skipped rather than stored under its number, because a
    # metric called "91" is a row nothing will ever read on purpose. Still deliberately absent:
    # height, which is not a measurement of training and does not change (#518); blood pressure
    # types 9 and 10, which are a pair of numbers that only mean anything together and which no
    # reader here has a use for; and everything in the Total biomarker pack, which #579
    # declines on the grounds that an unentitled field comes back absent rather than refused,
    # and a value that cannot be told from silence is worse than no value.
    METRICS = {
      1 => %w[weight kg],
      5 => %w[lean_mass kg],
      6 => ['fat_ratio', '%'],
      8 => %w[fat_mass kg],
      11 => %w[standing_hr bpm],
      76 => %w[muscle_mass kg],
      77 => %w[hydration kg],
      88 => %w[bone_mass kg]
    }.freeze

    MEASTYPES = METRICS.keys.join(',')

    # Readings Withings itself is not sure belong to this person.
    #
    # `attrib` 1 is a device measure that may belong to another user of the same scale, and 8
    # is the unconfirmed reading from a shared device. A household scale produces these, and
    # this table has nowhere to write "probably". Storing them would put a housemate's
    # bodyweight into a lifter's trend under the lifter's own account, where it is not
    # distinguishable from their own and quietly drags the average -- and a bodyweight trend
    # that is wrong by a kilogram in a way nobody can see is worse than one with a gap in it.
    #
    # So they are skipped, and only the two values that actually say "not necessarily you" are
    # skipped: everything else is stored, including attributes this list has never heard of.
    # The failure that costs more is dropping real readings, so the unknown case falls that way.
    AMBIGUOUS = [1, 8].freeze

    # How far behind the last successful fetch the next one starts.
    #
    # Health data arrives retroactively. A reading taken at 06:40 is fetched at 13:00, and a
    # scale that spent a weekend off the network backfills days later -- which is the whole
    # reason `measured_at` is a column separate from when the row appeared. A window that only
    # ever moved forward from `synced_at` would lose exactly those late arrivals, silently,
    # and they are the ones nobody can notice are missing.
    #
    # So it re-reads a week it has already read, every time. That is not waste: the unique
    # index on `[source, external_id]` turns the second read into a no-op, and being able to
    # re-read without consequence is what that index is for.
    OVERLAP = 7 * 24 * 60 * 60

    # How far back the *first* fetch reaches, when there is no `synced_at` to work from.
    #
    # A year, rather than everything. Long enough that a lifter who connects today gets a
    # trend worth reading rather than a single point -- a fortnight is the shortest window
    # bioimpedance says anything over -- and bounded rather than open-ended because a decade of
    # weigh-ins is not what anybody reads beside their training, and because an unbounded first
    # call is a lot of pages to fetch while somebody waits.
    BACKFILL = 365 * 24 * 60 * 60

    # How much of that window one request is allowed to ask for.
    #
    # A year in a single request is the cheapest way to read a year and the most expensive
    # thing to have refused. Withings answers a wide window a page at a time, and a page that
    # fails partway leaves the rows that did arrive in the table with nothing anywhere saying
    # which part of the window they are -- because the answer carries no order this app may
    # rely on. The published reference documents `more` and `offset` and says nothing
    # whatever about whether measure groups come back newest or oldest first; implementers
    # report having seen both, and at least one client sorts them itself rather than trust
    # it. So a truncated answer to a wide request cannot be turned into a resume point
    # without guessing which end it holds, and guessing wrong does not cost a slow loop -- it
    # costs a window silently skipped, which is the failure this module is built to avoid.
    #
    # Asking for the year a piece at a time replaces the guess with an arrangement. Each
    # piece is a window this app chose the ends of, so a piece that arrived whole is whole
    # whichever order it arrived in, and a piece that was refused is retried at a quarter of
    # the cost rather than the year being retried at all of it. That is the whole of #557's
    # fix: the ability to record progress comes from the boundaries being ours.
    #
    # A quarter, rather than a month or a half. Narrow enough that a refusal costs a quarter
    # of the work instead of all of it, wide enough that a year is four requests rather than
    # twelve -- and a quarter of daily weigh-ins is about ninety measure groups, comfortably
    # inside the hundreds Withings pages at, so the ordinary piece is one request and `more`
    # never fires within it at all.
    STEP = BACKFILL / 4

    # How stale the last fetch has to be before a read triggers another one.
    #
    # Withings' own guidance is not to ask for one user's measures more than once every ten
    # minutes, so this sits above that with room to spare. It is also short enough to be
    # useful: a lifter who weighs in and then asks gets the answer on the second ask rather
    # than tomorrow, which is the point of fetching on demand at all. And it is long enough
    # that a conversation making a dozen tool calls makes one HTTP call, not a dozen.
    STALE_AFTER = 15 * 60

    # A ceiling on the pages one fetch will follow. A year of daily weigh-ins is a few hundred
    # measure groups and Withings pages them in the hundreds, so this is far above any real
    # window; it is here because `more` is a loop condition that a provider controls, and a
    # loop a provider controls needs a bound that we control.
    MAX_PAGES = 20

    # What a fetch did, in enough detail for a caller to say so honestly.
    #
    # `outcome` is the whole answer and `stored` is only ever a count of rows that were new --
    # zero from a window with nothing in it, and zero again from a fetch that never got an
    # answer. Those are different facts and the outcome is what tells them apart.
    #
    # :fresh       the last fetch is recent enough that no call was made
    # :stored      the whole window arrived; `stored` counts what was new in it
    # :incomplete  part of the window arrived and then Withings stopped answering
    # :unreachable nothing arrived at all
    # :revoked     there is no usable token, which does mean the connection needs renewing
    # :absent      this account has never connected anything
    #
    # ## Shared with the sleep read, which is why the third member is not called `synced_at`
    #
    # #579 added a second read through the same grant, and the six outcomes above mean exactly
    # what they mean here: a night that did not arrive is `:incomplete` for the same reason a
    # quarter of weigh-ins is, and for the same reason neither may be rendered as an empty
    # week. A second struct carrying the same six symbols is how two modules come to disagree
    # about what one of them includes, which is the mistake `Withings.more?` exists to undo.
    #
    # So `read_at`, which is what the member has always held from a reader's point of view --
    # `Freshness` has called it `last_read_at` since #533. The old name was this module's own
    # column showing through the struct, and a sleep read putting `sleep_read_at` in a member
    # called `synced_at` would put the one confusion 052 is a whole migration about back into
    # the code that 052 keeps it out of the database.
    Fetch = Struct.new(:outcome, :stored, :read_at) do
      def to_s = outcome.to_s

      # Whether what is in the table can be read as the whole story. A caller that ignores
      # this and prints "no measurements" off a zero is telling somebody they have not weighed
      # themselves because a provider was rate limiting us.
      def failed? = %i[incomplete unreachable revoked].include?(outcome)
    end

    module_function

    # The entry point for anything about to read measurements: bring them up to date if they
    # are not, and otherwise do nothing at all.
    #
    # #519's three reading tools -- health_readings, bodyweight_trend and body_composition --
    # call this first, through MCP::Tools::Freshness, and then report the outcome it returns
    # alongside whatever they read. They are its only callers, and between #518 and #533 there
    # were none at all -- this module was finished, specced and wired to nothing, and the
    # symptom was a table that stayed empty while every other part of the app went on
    # reporting the connection as live.
    #
    # Cheap in the ordinary case, which is the case that matters -- one indexed row by account
    # id, and no network.
    def freshen(account_id, now: Time.now)
      row = WithingsConnection.of(account_id)
      return Fetch.new(:absent, 0, nil) unless row
      return Fetch.new(:fresh, 0, row[:synced_at]) if fresh?(row[:synced_at], now)

      fetch(account_id, now:)
    end

    def fresh?(synced_at, now) = !synced_at.nil? && synced_at > now - STALE_AFTER

    # The fetch itself, with no staleness check in front of it, so that a Sync button or a
    # task run by hand has something to call that means "now, regardless".
    #
    # Not guarded on `Withings.configured?`, deliberately. An access token already in hand
    # works without the client credentials -- those are needed to *refresh* it, not to spend
    # it -- so a deployment whose keys have been rotated out can still finish reading the
    # window it is in the middle of, and finds out the honest way when the refresh fails.
    def fetch(account_id, now: Time.now)
      row = WithingsConnection.of(account_id)
      return Fetch.new(:absent, 0, nil) unless row

      token = WithingsConnection.token(account_id)
      return Fetch.new(:revoked, 0, row[:synced_at]) unless token

      collect(account_id, token, row, now)
    end

    # Where the window that ends *now* starts: a week behind the last success, or a step back
    # where there has been no success to work from.
    #
    # Never further back than a step, whichever of the two it is. A window ending now is the
    # one whose arrival moves `synced_at`, and a step is as much as one request may ask for,
    # so capping it here is what keeps that claim to a single piece: it arrives whole or it
    # does not, and there is no case where half of it arrived and the resume point has to
    # guess which half. Everything older than the cap is not skipped -- it is read behind this
    # window, by the walk that records how far back it has got.
    #
    # The two callers this reads differently for are a first read, which used to start a year
    # back and now starts a step back with the rest of the year behind it, and a connection
    # nobody has read in longer than a step, which gets the same treatment for the same
    # reason.
    def since(synced_at, now)
      [synced_at ? synced_at - OVERLAP : now - BACKFILL, now - STEP].max
    end

    # The window, in pieces, stored, and each watermark moved only by a piece that arrived
    # whole.
    #
    # The walk stops at the first piece Withings does not answer in full, rather than trying
    # the rest. A refusal is what a short answer usually is -- status 601 arrives inside an
    # ordinary 200 -- and carrying on past one spends requests during the exact minutes the
    # provider is asking to be left alone. What did arrive is stored either way: the rows are
    # idempotent, the pieces that finished are written down, and the lifter who asked has this
    # morning's weigh-in, which is what they asked for.
    #
    # What it must not do is call the window complete, hence :incomplete -- a hole earlier in
    # the year is still a hole, and the reading tools say so.
    #
    # The failures carry the resume point as it stands *after* the walk rather than nil,
    # because "we could not reach Withings and the last thing we read was on Tuesday" is a
    # sentence somebody can act on and "we could not reach Withings" on its own is not.
    def collect(account_id, token, row, now)
      asked = windows(row, now)
      read = walk(account_id, token, row, asked, now)
      Fetch.new(outcome(read), read.sum { |stored, _| stored.to_i }, resumed(asked, read, row, now))
    end

    # Each piece in turn, newest first, stopping at the first that did not arrive whole.
    def walk(account_id, token, row, asked, now)
      read = []
      asked.each do |window|
        read << read_window(account_id, token, row, window, now)
        break unless read.last.last
      end
      read
    end

    # One piece: its pages, its rows and its watermark, all three together or none of them.
    #
    # The write is one transaction with the rows it is a claim about, so a watermark can never
    # outlive the readings it says have been fetched -- a process killed between the two would
    # otherwise leave this account permanently missing a quarter nothing will ask for again.
    def read_window(account_id, token, row, window, now)
      from, to = window
      groups, whole = pages(token, from, to)
      return [nil, false] if groups.nil?

      DB.transaction do
        stored = groups.sum { |group| store_group(account_id, group) }
        record(account_id, row, window, now) if whole
        [stored, whole]
      end
    end

    # Every window one fetch will ask for, newest first and meeting end to end.
    #
    # The first ends now, which is what lets it move `synced_at` when it arrives: everything
    # between its start and this instant has genuinely been read. Behind it come the pieces of
    # the year this account has not got back to yet, walked backwards, so a fetch cut short has
    # done the part worth having -- the recent readings are the ones a lifter reads, and the
    # recent end is what earns the fifteen-minute floor and the cheap window that follows from
    # it. The backfill walks its years newest first on the same argument.
    #
    # They meet end to end because a gap between two pieces is a fortnight nobody ever reads,
    # and nothing downstream could see it: the rows that did arrive are real and a chart drawn
    # from them looks exactly like a chart of a whole year.
    #
    # Ordinarily this is one window a week wide and nothing else. An account whose year is
    # behind it has nowhere further back to go, so the steady state costs one request, which is
    # what it cost before.
    def windows(row, now)
      stepped(since(row[:synced_at], now), now) + stepped(now - BACKFILL, reached(row, now))
    end

    # A span, cut into pieces no wider than a step, newest first. Empty where there is no span
    # left to ask about, which is how an account with its year behind it asks for nothing
    # extra. The bound on the loop is this app's own arithmetic rather than a provider's, so
    # unlike the page loop it does not need a ceiling: `to` falls by a step each time round.
    def stepped(from, to)
      pieces = []
      while to > from
        pieces << [[to - STEP, from].max, to]
        to -= STEP
      end
      pieces
    end

    # How far back this account has been read, which is where the walk behind the current
    # window picks up.
    #
    # Null only on a connection that has never finished a piece of anything, and then the walk
    # begins where the current window begins -- a step back, with the rest of the year behind
    # it. Every completed piece writes this column, so a connection with any success at all
    # has a real instant here and 046 gave one to the connections that predate it.
    def reached(row, now) = row[:measures_read_back_to] || since(row[:synced_at], now)

    # What a piece that arrived whole is allowed to claim.
    #
    # `synced_at` for the piece that ends now, and this is the line #557 turns on. It is not a
    # truncated read stamped as though it were whole: this piece arrived entirely, its end is
    # this instant, and everything still unread is older than its start because this app chose
    # that start -- not because of any assumption about which end of an answer Withings sends
    # first. Everything up to here really has been read, which is exactly what the column says.
    def record(account_id, row, window, now)
      from, to = window
      stamp = { measures_read_back_to: begins(row, from) }
      stamp[:synced_at] = now if to == now
      DB[:account_withings].where(account_id:).update(stamp)
    end

    # Where the stretch of readings that have genuinely been read begins, once this piece is
    # part of it.
    #
    # Ordinarily where it began before. A window starting a week behind the last success
    # overlaps what was already read, so the stretch grows at the top and its far end stays
    # wherever the walk has got back to -- which is why a steady-state read every quarter of an
    # hour does not drag this column forward over a year it has already fetched.
    #
    # It begins *here* where this piece does not touch that stretch at all: a connection nobody
    # has read in longer than a step leaves a gap between its last success and a window capped
    # at a step, and nothing has fetched that gap. Keeping the old far end would be claiming
    # the gap as read, which is the silent version of the failure this whole file is arranged
    # against. So the stretch restarts here and the walk behind it reads back down through the
    # gap, a piece at a time, at the cost of re-reading a year it has already got -- which the
    # unique index makes free of consequence and which is the cheaper of the two mistakes.
    def begins(row, from)
      reached = row[:measures_read_back_to]
      return from unless reached && row[:synced_at] && from <= row[:synced_at]

      [reached, from].min
    end

    # :stored only where every piece arrived whole, and :unreachable only where not one of
    # them was answered at all -- the distinction the whole module turns on, now that a fetch
    # is several requests. A first piece that answered and a second that did not is a window
    # with part of it in hand, whatever the counts are: an empty quarter that arrived is an
    # answer, and a quarter that was refused is not.
    def outcome(read)
      return :stored if read.all? { |_, whole| whole }
      return :unreachable if read.none? { |stored, _| stored }

      :incomplete
    end

    # Where the resume point stands when the walk is over: this instant if the piece ending
    # now arrived whole, and otherwise exactly where it was.
    def resumed(asked, read, row, now)
      _from, to = asked.first
      _stored, whole = read.first
      whole && to == now ? now : row[:synced_at]
    end

    # Every page of one piece of the window, and whether that really was every page.
    #
    # Withings answers a window wider than a page at a time and says so with `more`, handing
    # back the `offset` to resume from. Reading only the first page would drop the rest of the
    # piece without saying anything.
    #
    # Nil for the groups only where the *first* page failed, because then there is nothing to
    # be partially right about. A later page failing returns what did arrive and false, and the
    # caller above is what refuses to call that a complete piece.
    def pages(token, startdate, enddate)
      groups = []
      offset = nil
      MAX_PAGES.times do
        body = Withings.measures(token, meastypes: MEASTYPES, startdate:, enddate:, offset:)
        return [groups.empty? ? nil : groups, false] unless body

        groups.concat(body['measuregrps'] || [])
        return [groups, true] unless more?(body)

        offset = body['offset']
      end
      [groups, false]
    end

    # Deferred to `Withings.more?` rather than kept as a second copy. This module worked the
    # quirk out first and wrote its own answer; the workouts loop wrote a different one, took
    # the bare `body['more']` -- and `0` is truthy in Ruby, so a quiet window looped forever.
    # Two copies of one provider quirk is exactly how they came to disagree.
    def more?(body) = Withings.more?(body)

    # One weigh-in: several numbers taken at one moment, which is why they share a `grpid` and
    # a date. Stored as separate rows because they are separate metrics, and joined back up by
    # `measured_at` when #519 reads body composition as a set.
    def store_group(account_id, group)
      return 0 if AMBIGUOUS.include?(group['attrib'].to_i)

      measured_at = Time.at(group['date'].to_i)
      Array(group['measures']).sum { |measure| store_measure(account_id, group, measured_at, measure) }
    end

    # Returns 1 for a row that was new and 0 for one already held, so the count a caller gets
    # is what this fetch added rather than what the window contained. Sequel's `insert` under
    # ON CONFLICT DO NOTHING answers nil when nothing was written, which is the whole check.
    def store_measure(account_id, group, measured_at, measure)
      metric, unit = METRICS[measure['type'].to_i]
      return 0 unless metric

      written = DB[:health_metrics]
                .insert_conflict(target: %i[source external_id])
                .insert(account_id:, metric:, unit:, measured_at:, source: SOURCE,
                        value: real(measure), external_id: external_id(account_id, group, measure))
      written ? 1 : 0
    end

    # The quirk that bites. A measure is a `value` and a `unit`, and the number is
    # `value * 10 ** unit`: 81448 with unit -3 is 81.448 kg. Taking `value` at face value
    # stores a bodyweight of eighty-one thousand, which no constraint here refuses and which
    # would be discovered by a chart.
    #
    # Written as a decimal literal rather than as the arithmetic, because in Ruby `10 ** -3`
    # is a Float and `81448 * 0.001` is 81.44800000000001. Postgres would round that back to
    # three places and nobody would ever see it -- today. The column is numeric(10,3) because
    # three places is what a scale reports, not because three places is all a measurement can
    # ever need, and a Float rounded on the way in is a Float somebody later reads as exact.
    # `BigDecimal("81448e-3")` is the same number with none of that in it.
    #
    # Stored in the unit Withings gave, never converted. A kilogram turned into pounds on the
    # way in is a number the lifter never saw on their own scale, and converting back for
    # display loses a little more each time -- which is the argument 041 already made.
    def real(measure)
      BigDecimal("#{measure['value'].to_i}e#{measure['unit'].to_i}")
    end

    # The source's id for one reading, scoped to the account that fetched it.
    #
    # Withings identifies a weigh-in by `grpid` and each number within it by `type`, so that
    # pair is what makes re-reading an overlapping window a no-op instead of a duplicate.
    #
    # The account id in front of them is not decoration. The unique index is on
    # `[source, external_id]` across the whole table rather than per account, so a bare grpid
    # would mean one account's stored reading silently swallowing another's -- either because
    # Withings' ids are not as global as they look, or because two accounts here are connected
    # to one Withings login, which is what somebody with a second account does on purpose. In
    # both cases the symptom is readings that simply never arrive for the second lifter, and
    # nothing anywhere raises.
    def external_id(account_id, group, measure)
      "#{account_id}:#{group['grpid']}:#{measure['type'].to_i}"
    end
  end
end

