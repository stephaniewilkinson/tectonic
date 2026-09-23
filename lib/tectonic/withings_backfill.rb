# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'error_reporting'
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
  # stores with `store_all` and pairs with `pair`, which are the same three the rake task
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
    #   :nothing_left  -- every year back to the first stamped set has been read
    #   :refused       -- Withings did not answer, which is not the same as answering nothing
    #   :imported      -- a year was read, with the four numbers the rake task reports
    #
    # **`:refused` is the one that matters most.** Withings signal rate limiting as status
    # 601 inside an ordinary HTTP 200, `Withings.answered` folds it into the same nil as a
    # revoked token, and `Withings.workouts` hands this module that nil for a year it could
    # not read. A press that got nothing because Withings refused must not read as a press
    # that found nothing -- that is a lie about a year the lifter then never presses for
    # again. So a nil never advances the cursor and never renders as a total.
    #
    # ## What it does not do: stamp `workouts_backfilled_at`
    #
    # When this was written the reason was #554 -- `attempt` stamped that instant whenever the
    # years it *chose* to walk all answered, so a press routed through `run(since:)` would
    # have stamped it after one year and every later run would have believed the decade behind
    # it was read. That is fixed: only a walk that reached the earliest stamped set stamps it
    # now, and this method could safely call `run` without lying about anything.
    #
    # It still does not stamp, for a reason of its own that outlives #554. **A course of
    # presses can span calendar years.** Each press reads one year and the next reads the year
    # before, so a lifter who started pressing in 2023 and finished in 2026 has read 2023 down
    # to their first session and has never once been offered 2024 or 2025 -- and an instant
    # stamped at the end of that course would claim exactly those two years. What a press can
    # honestly write is the year it read, which is `workouts_imported_year` and which `advance`
    # only ever moves backwards.
    #
    # It also still calls `fetch_year`, `store_all` and `pair` directly rather than routing
    # through `run(since:)`, because those three are the whole of the walk and a second
    # expression of the logic around them is how the `more` bug in #553 came about.
    def slice(account_id:, pause: PAUSE)
      token = WithingsConnection.token(account_id)
      return { state: :disconnected } unless token

      plan = pending(account_id)
      return plan unless plan[:state] == :ready

      import(account_id, token, plan[:year], plan[:earliest], pause)
    end

    # What a press would do next, which the page has to be able to say *before* it is pressed.
    #
    # The same method answers both questions on purpose. A button offering to import 2023 and
    # a press that imports 2022 is the kind of disagreement that only shows up in front of a
    # lifter, and the way two answers to one question stay in agreement is for there to be
    # one answer.
    #
    # `years_left` counts this year and every year down to the floor, so a lifter can tell
    # "press again" from "press four more times" -- and so the page can stop asking at all
    # once there is nothing behind the button.
    def pending(account_id)
      floor = first_session_year(account_id)
      return { state: :no_sessions } unless floor

      year = next_year(account_id, floor)
      return { state: :nothing_left, earliest: floor } unless year

      { state: :ready, year:, earliest: floor, years_left: year - floor + 1 }
    end

    # The year the next press reads: this year for an account that has never pressed, and
    # otherwise the year before the last one read. Nil once that falls below the year of the
    # earliest stamped set, which is the same floor the task walks to and is a bound out of
    # Tectonic's own data -- a year before the first logged session holds nothing that could
    # ever be proposed to anything.
    #
    # It reads `workouts_imported_year` and not `workouts_backfilled_at`, and now that #554 is
    # fixed that is a choice about which question is being asked rather than a defence against
    # a column that lied. "Which year does the next press read" is answered by how far back
    # the reading has got, and the instant answers a different question -- when a walk last
    # reached the bottom -- which this has no use for. The cursor is also the one a narrowed
    # rake run writes, so a lifter who imported 2025 and 2024 from a terminal is offered 2023
    # here rather than being charged for the same two years again.
    #
    # The two ways of being wrong here are still not symmetrical, and that is what decides
    # every close call in this module: a cursor behind the truth costs one request to a year
    # already stored, and `WithingsWorkouts.store` makes re-storing an activity a no-op, while
    # a cursor ahead of the truth loses that year in silence.
    def next_year(account_id, floor)
      candidate = imported_year(account_id)&.pred || Date.today.year
      candidate < floor ? nil : candidate
    end

    def imported_year(account_id) = WithingsConnection.of(account_id)&.fetch(:workouts_imported_year, nil)

    # Fetch, store, advance, pair -- and the order is the whole of what makes a press safe to
    # repeat. The cursor moves only after a year has actually answered and been stored, so a
    # press that was refused, or that died between the fetch and the write, is a press that
    # simply has to be made again.
    #
    # `more` is the year another press would read, or nil where there is none. A lifter needs
    # to know whether to press again *and* whether to stop, and only one of those two can be
    # inferred from a screen that says neither.
    def import(account_id, token, year, floor, pause)
      activities = fetch_year(token, year, pause)
      return { state: :refused, year:, more: year } unless activities

      found = store_all(account_id, activities)
      advance(account_id, year)
      { state: :imported, year:, found:, more: next_year(account_id, floor) }.merge(offered(account_id))
    end

    # How far back this account's history has been read, by whichever route read it.
    #
    # 045 added it for the presses alone and said in as many words that the rake task would
    # never write it, because at the time the task's own watermark could be stamped for an
    # account with five unread years behind it and the button could not afford to believe
    # anything the task wrote. #554 closed that, and with the task no longer able to claim a
    # history it did not read there is no reason left for two private opinions of one number:
    # a year read from a terminal is a year read, and a lifter should not be asked to press
    # Import for it. Still emphatically not the measurement poll's `synced_at`, which is a
    # different question about different data -- see 043.
    #
    # **`LEAST`, so the cursor only ever moves backwards.** The presses walk down a year at a
    # time and would never move it forward on their own, but a task run narrowed with SINCE
    # reads the recent years and nothing else, and writing its floor in flat would drag the
    # cursor up over years somebody has already read -- handing them back to the button as
    # though nobody had ever fetched them. Postgres ignores NULLs inside `LEAST`, so the first
    # write on a row that has never read anything is the year itself, and the arithmetic
    # happens in the database rather than in a read-then-write this module would have to hold
    # a lock across.
    def advance(account_id, year)
      DB[:account_withings].where(account_id:)
                           .update(workouts_imported_year: Sequel.function(:least, :workouts_imported_year, year))
    end

    # The pairing, with the one exception #555 describes kept off a lifter's screen.
    #
    # A proposal whose session was matched to a *different* activity is never cleared, so a
    # later run can pick a second activity for that session and the `UPDATE` in `offer` hits
    # the unique index on `proposed_workout_id`. From a rake task that is a stack trace after
    # the API budget is already spent; from a button it is a 500 on the settings page of
    # somebody who pressed Import, with the year they just paid for looking like it failed.
    #
    # It is caught rather than fixed, because the fix belongs to #555 and is a change to what
    # `outstanding` counts -- guarding `offer` here would be the second half of that fix
    # living somewhere nobody would think to look for it. What is bought instead is honesty:
    # the activities are stored and committed, the cursor has moved, and the report says the
    # matching could not be finished rather than reporting four zeroes as though it had.
    def offered(account_id)
      pair(account_id)
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
      walked.merge(pair(account_id)).merge(years:, state: :walked, **settled)
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
    # So the walk now writes down **what it actually read** rather than the fact that it
    # finished, and the two things it can honestly say about itself turn out to be two
    # different facts about one claim:
    #
    #   `workouts_imported_year` -- how far back this account's history has been read.
    #   `workouts_backfilled_at` -- when a read last reached the bottom of it.
    #
    # ## Why that is two columns and not one, having looked hard at making it one
    #
    # 045 added the year cursor for the import button and the obvious tidy answer to #554 is
    # to delete the instant and keep it: one column, one meaning, nothing to confuse. It does
    # not work, and the reason is worth writing down so nobody spends the afternoon on it
    # again. A year on its own cannot say **when** it was written, and the resume needs that:
    # a walk that read 2019 through 2023 in 2023 has said nothing whatever about 2024 and
    # 2025, so a task resuming from the year alone must either re-walk the whole history every
    # single run -- a request per year, forever, for a saving the instant used to buy -- or
    # skip years nobody has read, which is the bug it was sent to fix. An instant on its own
    # cannot say **how far back**, which is #554 exactly. The two facts are genuinely two.
    #
    # What they are not is two watermarks for two jobs. Both routes into this module read
    # years and both write the cursor, so a walk from the terminal and a press on the settings
    # page now agree about how far back the history has been read instead of each keeping a
    # private opinion of it -- a lifter who ran the task does not then get asked to press
    # Import for the years it already fetched.
    #
    # ## Why the cursor cannot raise the task's floor, though the instant can
    #
    # `workouts_imported_year` is a floor of what *has* been read and says nothing at all
    # about the years above it being fresh. Using it to raise the walk's floor would be the
    # same mistake in the other direction: a cursor of 2019 written in 2023 would have a 2026
    # run start at 2019 and stop... at 2019, having never asked about the three years since.
    # The instant is the only thing here that carries a date, so it is the only thing that can
    # say a *recent* year has been covered -- and it can only say that because it is now
    # stamped by a walk that reached the bottom, which is the change #554 asked for.
    def settle(account_id, years, walked)
      floor = first_session_year(account_id)
      lowest = lowest_read(years, walked)
      return { read_back_to: nil, earliest: floor } unless lowest

      advance(account_id, lowest)
      stamp(account_id) if floor && lowest <= floor
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
    # A previous walk that **reached the earliest stamped set** moves the floor up to the year
    # it ran in: everything older than such a walk has already been read and stored, and
    # re-reading a decade to write the same rows again is a request a year for nothing. Its
    # own year and not the year after, because the walk happened part way through it.
    #
    # It is `workouts_backfilled_at` and not `workouts_imported_year` that raises this floor,
    # and the two are not interchangeable here: the cursor is a floor of what has been read
    # and carries no date, so it cannot say anything about the years since it was written. See
    # `settle`, where the distinction is argued at length and where #554 came from.
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

    # The instant a read last reached the bottom of this lifter's history, which is the whole
    # of what "everything older than this has been read" is entitled to mean.
    #
    # Stamped by `settle` and nowhere else, and only where the oldest year the walk read sits
    # at or below the year of the earliest stamped set. A SINCE below that floor still stamps
    # -- an operator naming 2015 for a lifter who started in 2019 has read every year that
    # could hold a matchable session, and refusing them the stamp would make every later run
    # re-read the same decade for nothing. A SINCE above it never stamps, which is #554.
    #
    # And **not `synced_at`**, which belongs to the measurement poll. Stamping that one from a
    # workout fetch would tell the poll it had already read a window of bodyweights nobody has
    # fetched, and those readings would never arrive -- silently, with nothing raised and a
    # fortnight simply missing from a chart.
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

