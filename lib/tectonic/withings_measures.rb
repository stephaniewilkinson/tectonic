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
    # Deliberately absent: height, which is not a measurement of training and does not change;
    # blood pressure and heart rate, which #472 puts with the rest of `user.activity` under a
    # later ticket. A type this table does not name is skipped rather than stored under its
    # number, because a metric called "91" is a row nothing will ever read on purpose.
    METRICS = {
      1 => %w[weight kg],
      5 => %w[lean_mass kg],
      6 => ['fat_ratio', '%'],
      8 => %w[fat_mass kg],
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
    Fetch = Struct.new(:outcome, :stored, :synced_at) do
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

    # Where a window starts: a week behind the last success, or a year back on the first run.
    def since(synced_at, now)
      synced_at ? synced_at - OVERLAP : now - BACKFILL
    end

    # The window, stored, and `synced_at` moved only if the whole of it arrived.
    #
    # A short read still writes what it got. The rows are idempotent and the resume point has
    # not moved, so the next fetch asks for the same window again and loses nothing -- and in
    # the meantime the lifter who asked has this morning's weigh-in, which is what they asked
    # for. What it must not do is claim the window is complete, hence :incomplete.
    #
    # The failures carry the *old* `synced_at` rather than nil, because "we could not reach
    # Withings and the last thing we read was on Tuesday" is a sentence somebody can act on
    # and "we could not reach Withings" on its own is not.
    def collect(account_id, token, row, now)
      groups, whole = pages(token, since(row[:synced_at], now), now)
      return Fetch.new(:unreachable, 0, row[:synced_at]) if groups.nil?

      stored = DB.transaction { groups.sum { |group| store_group(account_id, group) } }
      return Fetch.new(:incomplete, stored, row[:synced_at]) unless whole

      DB[:account_withings].where(account_id:).update(synced_at: now)
      Fetch.new(:stored, stored, now)
    end

    # Every page of the window, and whether that really was every page.
    #
    # Withings answers a wide window a page at a time and says so with `more`, handing back the
    # `offset` to resume from. Reading only the first page would keep the newest readings and
    # drop the older end of the window without saying anything, which on a first fetch is most
    # of the year.
    #
    # Nil for the groups only where the *first* page failed, because then there is nothing to
    # be partially right about. A later page failing returns what did arrive and false, and the
    # caller above is what refuses to call that a complete window.
    def pages(token, startdate, now)
      groups = []
      offset = nil
      MAX_PAGES.times do
        body = Withings.measures(token, meastypes: MEASTYPES, startdate:, enddate: now, offset:)
        return [groups.empty? ? nil : groups, false] unless body

        groups.concat(body['measuregrps'] || [])
        return [groups, true] unless more?(body)

        offset = body['offset']
      end
      [groups, false]
    end

    # `more` is documented as a number and has been observed as a boolean, so both are read
    # rather than picking one and finding out in production that the loop ran once.
    def more?(body) = body['more'] == true || body['more'].to_i.positive?

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

