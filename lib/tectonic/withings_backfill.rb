# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'timing'
require_relative 'withings'
require_relative 'withings_connection'
require_relative 'withings_proposals'
require_relative 'withings_workouts'

class Tectonic < Roda
  # Reading a lifter's Withings history once, and offering what it finds to the sessions they
  # already logged. The historical half of #520 -- which #520 declined.
  #
  # ## The decision this reverses
  #
  # #520 refuses a backfill in as many words: *"matching an arbitrary past session is the
  # hard version of this problem and this flow avoids it entirely."* That was the right call
  # for the forward flow and it is written into 042's notes as well. The owner was asked
  # afterwards and chose to build the hard version anyway, as a second piece standing on the
  # first rather than replacing it. So this is deliberate, not an oversight -- and what it
  # reverses is the *scope* and nothing else. Every pairing here is a proposal a lifter
  # confirms or dismisses through the same two routes the record page already posts to.
  # **Nothing in this file ever writes `workout_id`.**
  #
  # ## Why it is a rake task and cannot be anything else
  #
  # `Withings::TIMEOUT` is ten seconds per call, which is the right number for a settings
  # page and the wrong one for a hundred paginated calls: a walk over a decade can stand at a
  # request boundary for minutes, and a Puma thread spent that way is a thread not serving
  # anybody. It is also nowhere near `preDeployCommand`, which runs on every deploy -- a
  # deploy that reached out to Withings would turn somebody else's bad afternoon into a
  # failed release, and would do it on every push.
  #
  # ## Chunked by year, because a truncated answer looks exactly like an empty one
  #
  # `getworkouts` takes `startdateymd`/`enddateymd` and nothing documents a maximum width for
  # that range. An undocumented limit is not a limit that does not exist -- it is one that
  # reports itself by returning fewer rows, and a short answer from this endpoint is
  # indistinguishable from a quiet year. A year per request is narrow enough that a ceiling
  # measured in months would have to be absurd to bite, and `Withings.workouts` follows
  # `more`/`offset` within each year so a busy one is not cut off at the twentieth activity.
  #
  # ## How far back, and why not "stop when a year is empty"
  #
  # The floor is **the year of this lifter's earliest stamped set**, and that bound comes out
  # of Tectonic's own data rather than out of a guess about Withings. It is exact for the job:
  # this exists to propose matches against sessions that were logged here, so a year before
  # the first logged session contains nothing that could ever be proposed, and asking about it
  # is a request whose answer has nowhere to go.
  #
  # The obvious alternative -- walk back until a year comes up empty -- is refused on purpose.
  # A lifter who trained through 2022, took 2023 off the watch, and came back in 2024 has a
  # hole in the middle of their history, and a walk that stopped at the first empty year would
  # silently decide their training began in 2024. "Nothing in this year" and "nothing before
  # this year" are different claims and the API cannot tell them apart. SINCE overrides the
  # floor for an operator who wants a cheaper run, or who knows something this does not.
  #
  # ## Newest year first
  #
  # So that a walk cut short by a throttle has done the part worth having. The sessions a
  # lifter can still remember well enough to confirm are the recent ones; a run that dies in
  # 2019 having already offered everything from 2024 and 2025 has produced something useful,
  # where the same run in the other order would have produced a decade of nothing.
  module WithingsBackfill
    # Seconds between one request and the next, and between one year and the next.
    #
    # Withings ask not to be polled more often than once every ten minutes per user, and the
    # commonly cited application ceiling is 120 requests a minute. A serial walk pausing a
    # second is far under both -- ten years is ten requests and ten seconds -- while the same
    # walk with no pause is a tight loop against somebody else's service. The cost of being
    # wrong is not a slow run: it is status 601, which arrives as HTTP 200 and folds into the
    # same nil as a revoked token, so being throttled looks from here like being finished.
    PAUSE = 1.0

    module_function

    # The whole run: walk the history, store what comes back, offer it to the sessions that
    # have none. A report hash and never a boolean, because there are four numbers a lifter
    # needs afterwards and a run that answers "true" has said nothing about any of them.
    #
    # `dry_run` does the *real* thing inside a transaction that always rolls back, rather
    # than a second code path that estimates what the first one would do. An estimate written
    # separately is an estimate that drifts, and the drift shows up as a preview that says
    # eleven and a run that writes nine. The API calls still happen -- there is no way to
    # report honestly on a history without reading it -- so a dry run costs the same requests
    # and leaves the database exactly as it found it.
    def run(account_id:, since: nil, dry_run: false, pause: PAUSE)
      token = WithingsConnection.token(account_id)
      return { state: :disconnected } unless token

      years = years_to_walk(account_id, since)
      return { state: :no_sessions } unless years

      return attempt(account_id, token, years, pause) unless dry_run

      rehearse(account_id, token, years, pause)
    end

    def rehearse(account_id, token, years, pause)
      report = nil
      DB.transaction(rollback: :always) { report = attempt(account_id, token, years, pause) }
      report.merge(dry_run: true)
    end

    # Walk, then pair, then stamp -- and pair even where the walk failed part way, because
    # the years that did answer are worth offering and the report says plainly that the rest
    # were never read. What a partial run must not do is *claim* to be complete, which is why
    # the watermark below is stamped on `complete` alone.
    def attempt(account_id, token, years, pause)
      walked = walk(account_id, token, years, pause)
      stamp(account_id) if walked[:complete]
      walked.merge(pair(account_id)).merge(years:, state: :walked)
    end

    # A year at a time, newest first, stopping at the first year Withings does not answer.
    #
    # **A failed year ends the walk rather than being skipped.** `Withings.workouts` answers
    # nil for a page that failed and `[]` for a year that was genuinely empty, and that
    # distinction is the only thing standing between "2021 had no activities" and "we were
    # rate-limited in 2021". Carrying on past a nil would turn a throttle into a decade of
    # confident silence -- and the walk would report itself complete, stamp the watermark,
    # and never look at those years again.
    def walk(account_id, token, years, pause)
      found = 0
      years.each do |year|
        activities = fetch_year(token, year, pause)
        return { found:, complete: false, stopped_at: year } unless activities

        found += store_all(account_id, activities)
        sleep pause if pause.positive? && year != years.last
      end
      { found:, complete: true, stopped_at: nil }
    end

    # Civil dates, which is what this endpoint takes. December 31st of the current year is in
    # the future and that is fine: an end date beyond today bounds a range rather than asking
    # for anything that has not happened.
    def fetch_year(token, year, pause)
      Withings.workouts(token, from: Date.new(year, 1, 1), to: Date.new(year, 12, 31), pause:)
    end

    # Storage is `WithingsWorkouts.store` and deliberately not a second upsert written here.
    # That one already omits `workout_id` and `dismissed_at` from its update list, which is
    # the property that makes re-running this safe: a backfill run twice must not un-answer a
    # question the lifter has answered, and the way to inherit that guarantee is to go
    # through the code that carries it rather than to restate it and hope.
    def store_all(account_id, activities)
      DB.transaction { activities.each { |activity| WithingsWorkouts.store(account_id, activity) } }
      activities.length
    end

    # Which years to ask about, newest first, or nil where there is nothing to match against.
    #
    # A previous *complete* walk moves the floor up to its own year: everything older than a
    # completed walk has already been read and stored, and re-reading a decade to write the
    # same rows again is a hundred requests for nothing. Its own year and not the year after,
    # because the walk happened part way through it.
    #
    # SINCE overrides both bounds rather than being folded into them with `max`. An operator
    # naming a year is making a claim this module cannot check -- that the interesting
    # history starts there, or that the last run's watermark is not to be trusted -- and a
    # bound that silently ignored them would be worse than no bound at all.
    def years_to_walk(account_id, since)
      first = first_session_year(account_id)
      return nil unless first
      return (since..Date.today.year).to_a.reverse if since

      floor = [first, resumed_year(account_id)].compact.max
      (floor..Date.today.year).to_a.reverse
    end

    # The year of the earliest stamped set, which is where this lifter's matchable history
    # begins. Off `sets.completed_at` and never off `workouts.date`, for the same reason the
    # matcher is: that column only ever holds midnight, so it would put the floor a year early
    # for a session logged on January 1st and could not be relied on for anything finer.
    def first_session_year(account_id)
      DB[:sets].join(:workouts, id: :workout_id)
               .where(Sequel[:workouts][:account_id] => account_id)
               .exclude(Sequel[:sets][:completed_at] => nil)
               .min(Sequel[:sets][:completed_at])&.year
    end

    def resumed_year(account_id) = WithingsConnection.of(account_id)&.fetch(:workouts_backfilled_at, nil)&.year

    # The backfill's own high-water mark, and **not `synced_at`**, which belongs to the
    # measurement poll. Stamping that one from a workout fetch would tell the poll it had
    # already read a window of bodyweights nobody has fetched, and those readings would never
    # arrive -- silently, with nothing raised and a fortnight simply missing from a chart.
    def stamp(account_id)
      DB[:account_withings].where(account_id:).update(workouts_backfilled_at: Time.now)
    end

    # Offering what was stored to the sessions that have nothing, one session at a time.
    #
    # Greedy, oldest session first, and an activity offered to one session is out of the
    # running for the next. That is not the optimal assignment over the whole history -- a
    # proper one would be a matching problem over a bipartite graph -- and the reason it does
    # not need to be is that contested overlaps barely exist: two Tectonic sessions rarely
    # overlap each other in time, so the candidate sets are nearly disjoint and greedy and
    # optimal agree. Where they do not, the lifter says no and the activity goes back into
    # the pool on the next run.
    def pair(account_id)
      tally = { proposed: 0, already_waiting: 0, without_activity: 0 }
      claimed = []
      sessions(account_id).each { |session| tally[offer(account_id, session, claimed)] += 1 }
      tally.merge(activities_without_session: unoffered(account_id))
    end

    # One session's turn, and which of the three things happened to it.
    #
    # A session that already has a proposal waiting is left exactly as it is. That is what
    # makes a second run a no-op rather than a second set of proposals -- and it is also what
    # keeps a re-run from quietly swapping a waiting proposal for a different activity
    # between the lifter reading the page and answering it.
    #
    # The write names `proposed_workout_id: nil` in its filter as well, so an offer that
    # appeared underneath this one -- another run, a half-open session -- is refused rather
    # than overwritten.
    def offer(account_id, session, claimed)
      window = session[:window]
      return :already_waiting if WithingsWorkouts.standing(account_id, session[:id], window)

      pick = WithingsWorkouts.best(available(account_id, window, session[:id], claimed), window)
      return :without_activity unless pick

      claimed << pick[:id]
      DB[:withings_workouts].where(id: pick[:id], proposed_workout_id: nil)
                            .update(proposed_workout_id: session[:id])
      :proposed
    end

    # The scoring is the forward flow's, entire: the same overlap gate, the same ratio, the
    # same quarter-point for a lifting category, the same nearest-start tie-break. A second
    # scorer would be a second answer to "is this recording of this session", and the two
    # would disagree eventually -- on an old session, where nobody would be watching.
    def available(account_id, window, workout_id, claimed)
      WithingsWorkouts.candidates(account_id, window, workout_id)
                      .reject { |row| claimed.include?(row[:id]) }
    end

    # Every session that could still take an offer, with the interval to score against.
    #
    # Already-matched sessions are excluded because they are answered, and dismissed ones
    # because #520 requires a no to stick permanently -- a backfill that re-proposed to a
    # session the lifter had waved away would be the nagging the issue forbids, arriving
    # months later and in bulk.
    #
    # A session with no stamped sets drops out here rather than being counted as one the
    # watch recorded nothing for, and the difference is worth keeping: a written but untrained
    # session, which is most of what a generated programme week is, has no interval and
    # therefore no question to ask about it. Counting those would put a number in the report
    # that grows every time somebody generates a week.
    def sessions(account_id)
      matched = DB[:withings_workouts].where(account_id:).exclude(workout_id: nil).select_map(:workout_id)
      rows = DB[:workouts].where(account_id:, withings_dismissed_at: nil)
                          .exclude(id: matched).order(:date, :id).all
      stamps = WithingsProposals.stamps_for(rows.map { |row| row[:id] })
      rows.filter_map { |row| session_window(row, stamps.fetch(row[:id], [])) }
    end

    # `Timing.session` and `WithingsWorkouts.interval`, in that order, which is exactly what
    # the record page does. The interval a session is matched on is one idea and it lives in
    # one place; a backfill that read `min(completed_at)` out of the database itself would be
    # a second reading of it, and the day the two disagreed would be the day a year of
    # proposals was subtly wrong.
    def session_window(row, sets)
      window = WithingsWorkouts.interval(Timing.session(row, sets))
      window && { id: row[:id], date: row[:date], window: }
    end

    # Activities nobody has been asked about and no session wants: stored, unclaimed,
    # un-refused and unoffered. The honest name for these is "the watch recorded something
    # Tectonic has no session for" -- a walk, a bike ride, or a session trained and never
    # logged -- and the count is reported rather than swallowed because it is the number that
    # tells a lifter whether the matching worked or merely ran.
    def unoffered(account_id)
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil,
                                   proposed_workout_id: nil).count
    end
  end
end

