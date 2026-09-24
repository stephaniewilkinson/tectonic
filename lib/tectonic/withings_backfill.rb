# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'error_reporting'
require_relative 'timing'
require_relative 'withings'
require_relative 'withings_connection'
require_relative 'withings_pairing'
require_relative 'withings_read_range'
require_relative 'withings_proposals'
require_relative 'withings_answers'
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
  # ## Why the whole walk is a rake task and cannot be anything else
  #
  # `Withings::TIMEOUT` is ten seconds per call, which is the right number for a settings
  # page and the wrong one for a hundred paginated calls: a walk over a decade can stand at a
  # request boundary for minutes, and a Puma thread spent that way is a thread not serving
  # anybody. It is also nowhere near `preDeployCommand`, which runs on every deploy -- a
  # deploy that reached out to Withings would turn somebody else's bad afternoon into a
  # failed release, and would do it on every push.
  #
  # ## And why there is a second entry point anyway. #558
  #
  # Everything above is an argument about *a decade in one request*, and none of it is an
  # argument against a year. #558 is the hole it left: the whole of a lifter's history could
  # only be imported from a shell with the production database in reach, which is not a thing
  # the person this app is for has -- so the forward flow worked and their own history was
  # unreachable. A worker process would be the textbook answer and is the one #458 declined
  # and #518 declined again; it is a second paid service to run something a lifter presses
  # perhaps five times in their life.
  #
  # So `slice` is the same walk, bounded to what a request can afford honestly: **one year
  # per press**, which is one request to Withings in the ordinary case, and the page says how
  # many years are left so the lifter knows whether to press again. It is a narrower entry
  # point into this module rather than a second walker -- it fetches with `fetch_year`,
  # stores with `store_all` and pairs with `WithingsPairing.pair`, which are the same three the rake task
  # runs -- because a second expression of this logic is exactly how the `more` bug in #553
  # came about, and this module's whole contract is that a nil year and an empty year are
  # different things.
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

    # One year, on the request path, for a lifter with no terminal. #558.
    #
    # Five states and they are five rather than two, on the same argument `proposal` makes
    # about its four: the differences between them are the whole substance of the feature.
    #
    #   :disconnected  -- no usable token, so there is nobody to ask
    #   :no_sessions   -- nothing logged here, so a history has nothing to be offered to
    #   :nothing_left  -- every year from the first stamped set to this one has been read
    #   :refused       -- Withings did not answer, which is not the same as answering nothing
    #   :imported      -- a year was read, with the four numbers the rake task reports
    #
    # **`:refused` is the one that matters most.** Withings signal rate limiting as status
    # 601 inside an ordinary HTTP 200, `Withings.answered` folds it into the same nil as a
    # revoked token, and `Withings.workouts` hands this module that nil for a year it could
    # not read. A press that got nothing because Withings refused must not read as a press
    # that found nothing -- that is a lie about a year the lifter then never presses for
    # again. So a nil never widens the range of years recorded as read, and never renders as a
    # total.
    #
    # It also still calls `fetch_year`, `store_all` and `WithingsPairing.pair` directly rather than routing
    # through `run(since:)`, because those three are the whole of the walk and a second
    # expression of the logic around them is how the `more` bug in #553 came about.
    def slice(account_id:, pause: PAUSE)
      token = WithingsConnection.token(account_id)
      return { state: :disconnected } unless token

      plan = WithingsReadRange.pending(account_id)
      return plan unless plan[:state] == :ready

      import(account_id, token, plan[:year], pause)
    end

    # Fetch, store, record, pair -- and the order is the whole of what makes a press safe to
    # repeat. The claim moves only after a year has actually answered and been stored, so a
    # press that was refused, or that died between the fetch and the write, is a press that
    # simply has to be made again.
    #
    # `more` is the year another press would read, or nil where there is none. A lifter needs
    # to know whether to press again *and* whether to stop, and only one of those two can be
    # inferred from a screen that says neither. It is asked of `WithingsReadRange.pending` rather than worked out
    # here, because that is the method the page asks the same question of a moment later and a
    # report that disagreed with the button under it would be a disagreement only a lifter ever
    # saw. `catching_up` is which of the two gaps that year sits in, which the page needs
    # because "2024 and earlier" is a true sentence about a walk backwards and a false one
    # about a press filling the years since the last read. #566.
    def import(account_id, token, year, pause)
      activities = fetch_year(token, year, pause)
      return { state: :refused, year:, more: year } unless activities

      found = store_all(account_id, activities)
      WithingsReadRange.record_read(account_id, year, year)
      next_press = WithingsReadRange.pending(account_id)
      { state: :imported, year:, found:, more: next_press[:year],
        catching_up: !next_press[:unread_from].nil? }.merge(offered(account_id))
    end

    # The pairing, with the last thing that can raise out of it kept off a lifter's screen.
    #
    # **#555 is fixed rather than caught now**, and this stays for what the fix cannot reach.
    # What it was written for was a proposal nobody could answer holding a session's slot
    # under the unique index on `proposed_workout_id`: `WithingsPairing.offer` gives those up before it writes
    # and guards the write on the session id as well as on the row, so a single walk no longer
    # meets one. Two walks at once still can -- both can read no row and both can write, and
    # an index is the only thing that can settle that, which is what an index is for.
    #
    # So the rescue is no longer standing in for a bug; it is standing in front of a race this
    # process cannot see the other half of. What it buys is unchanged and is the reason it is
    # a rescue rather than a retry: the activities are stored and committed, the cursor has
    # moved, and the report says the matching could not be finished rather than reporting four
    # zeroes as though it had. Pressing Import again re-pairs, because pairing is the part of
    # this module that is free to repeat.
    def offered(account_id)
      WithingsPairing.pair(account_id)
    rescue Sequel::UniqueConstraintViolation => e
      report(e)
      { pairing: :stalled }
    end

    def report(exception)
      return unless ErrorReporting.on?

      Sentry.capture_exception(exception)
    rescue StandardError
      # Reporting a failure must never become a second one, on the request path least of all.
    end

    # Walk, then write down what was read, then pair -- and pair even where the walk failed
    # part way, because the years that did answer are worth offering and the report says
    # plainly that the rest were never read.
    #
    # The two numbers `settle` works out are reported as well as written down, because the
    # other half of #554 is that nothing ever *said* a narrowed run had left years behind: the
    # task printed a completed walk and the operator had no way to tell that from a walk of
    # the whole history. `read_back_to` and `earliest` together are that sentence.
    def attempt(account_id, token, years, pause)
      walked = walk(account_id, token, years, pause)
      settled = settle(account_id, years, walked)
      walked.merge(WithingsPairing.pair(account_id)).merge(years:, state: :walked, **settled)
    end

    # What a walk leaves written down, which #554 is the story of getting wrong.
    #
    # It used to be one line -- `stamp(account_id) if walked[:complete]` -- and the word doing
    # the damage was `complete`, which means "every year I chose to walk answered" and was
    # being read as "every year back to the first session has been read". Those are the same
    # sentence only for a walk that chose the whole history. `rake withings:backfill
    # ACCOUNT_ID=1 SINCE=2024` for a lifter whose earliest stamped set is 2019 completes in
    # two years, stamped an instant whose own meaning is "everything older than this has been
    # read", and every default run afterwards floored at `[2019, 2026].max`. 2019 through 2023
    # were never read and no later run would ever have read them. The task reported a
    # completed walk, because from its own point of view it had completed one.
    #
    # So the walk now writes down **what it actually read**, as the two ends of one range:
    #
    #   `workouts_imported_year`         -- how far back this account's history has been read.
    #   `workouts_imported_through_year` -- how far forward.
    #
    # The second arrived with #566 and 049 argues it; the short version is that "read back to
    # 2019" was being read as "and everything above 2019 too", which is true on the day a walk
    # finishes and false a year later. The walk always tops out at this year -- see
    # `years_to_walk` -- so the top it records is `years.first`, and that is a fact about the
    # walk rather than a guess: it asked for this year and this year answered.
    #
    # There used to be a third, `workouts_backfilled_at`: the instant a walk last reached the
    # earliest stamped set, kept because "a year cannot say when it was written". Only its year
    # was ever read, and only to raise the next walk's floor -- and a range whose bottom reaches
    # the earliest stamped set says the same thing better. Its top is the newest year read, so
    # a walk resuming there re-reads that year and everything after it, which is exactly what
    # the instant's year bought, and it also knows about a course of presses on the settings
    # page, which never stamped the instant. 055 dropped it (#600). `resumed_year` holds the
    # rule, and the bottom-reaches-the-floor guard in it is what #554 is about: a range that
    # stops short of the first session says nothing about the years under it.
    #
    # Both routes into this module read years and both write the same two ends, so a walk from
    # the terminal and a press on the settings page agree about which years have been read
    # instead of each keeping a private opinion of it -- a lifter who ran the task does not
    # then get asked to press Import for the years it already fetched, and a lifter who pressed
    # Import to the bottom does not have the task walk it all again.
    def settle(account_id, years, walked)
      floor = first_session_year(account_id)
      lowest = lowest_read(years, walked)
      return { read_back_to: nil, earliest: floor } unless lowest

      WithingsReadRange.record_read(account_id, lowest, years.first)
      { read_back_to: lowest, earliest: floor }
    end

    # The oldest year that actually answered, or nil where none did.
    #
    # The years are contiguous and descending, so a walk that ran out at `stopped_at` read
    # every year above it and that year not at all -- `stopped_at + 1` rather than
    # `stopped_at`, because the difference between them is a year of training and this module
    # exists to stop that difference being lost. A walk refused in the very first year it
    # asked about has read nothing, and "read nothing" is not a year: it is nil, and nothing
    # is written down at all.
    def lowest_read(years, walked)
      return years.last if walked[:complete]
      return nil if walked[:stopped_at] == years.first

      walked[:stopped_at] + 1
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

    # Storage is `WithingsActivity.store` and deliberately not a second upsert written here.
    # That one already omits `workout_id` and `dismissed_at` from its update list, which is
    # the property that makes re-running this safe: a backfill run twice must not un-answer a
    # question the lifter has answered, and the way to inherit that guarantee is to go
    # through the code that carries it rather than to restate it and hope.
    def store_all(account_id, activities)
      DB.transaction { activities.each { |activity| WithingsActivity.store(account_id, activity) } }
      activities.length
    end

    # Which years to ask about, newest first, or nil where there is nothing to match against.
    #
    # A history already read **down to the earliest stamped set** moves the floor up to the
    # newest year that read reached: everything below it has been read and stored, and
    # re-reading a decade to write the same rows again is a request a year for nothing. That
    # year itself and not the one after, because the read that reached it may have happened
    # part way through it. See `resumed_year`.
    #
    # SINCE overrides both bounds rather than being folded into them with `max`. An operator
    # naming a year is making a claim this module cannot check -- that the interesting
    # history starts there, or that the last run's watermark is not to be trusted -- and a
    # bound that silently ignored them would be worse than no bound at all.
    def years_to_walk(account_id, since)
      first = first_session_year(account_id)
      return nil unless first
      return (since..Date.today.year).to_a.reverse if since

      floor = [first, resumed_year(account_id, first)].compact.max
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

    # Where a walk can start, having been told where this lifter's history begins: the top of
    # what has been read, but only where what has been read reaches all the way down to it.
    # Nil otherwise, which walks from the bottom.
    #
    # The guard is #554. A range from a walk narrowed to the recent years, or from a few presses
    # of the import button, stops short of the earliest stamped set and says nothing about the
    # years below it -- resuming from its top would skip them for good. A range that reaches
    # the bottom has read every year from there to its top, by whichever route, so starting at
    # its top re-reads that year (it may have been read part way through) and skips nothing.
    #
    # And the top rather than any date, because the top is already the newest year read: a
    # range of 2019-2023 read in 2023 has a 2026 run start at 2023, which is right, since
    # 2024 and 2025 were never asked about.
    def resumed_year(account_id, floor)
      read = WithingsReadRange.imported_range(account_id)
      read && read.first <= floor ? read.last : nil
    end
  end
end

