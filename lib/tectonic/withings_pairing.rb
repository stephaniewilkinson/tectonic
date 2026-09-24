# frozen_string_literal: true

require_relative 'db'
require_relative 'timing'
require_relative 'withings_answers'
require_relative 'withings_proposals'
require_relative 'withings_workouts'

class Tectonic < Roda
  # Offering the activities a backfill stored to the sessions that have no answer yet. #605.
  #
  # Out of WithingsBackfill, which reads years from Withings and records which years it read,
  # because this reads nothing from Withings and records nothing about years. It runs after
  # either route into the backfill -- a walk from the terminal or a press of the import button
  # -- over whatever is stored by then, and both call it here rather than each keeping a copy.
  # The scoring it offers by is WithingsWorkouts', so the record page and the review list
  # cannot disagree about which activity belongs to a session.
  module WithingsPairing
    module_function

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
    # `reclaim` first, because `standing` can only see a proposal that is still a question and
    # a dead one holds the session's slot just as firmly. See #555: an activity claimed by
    # another session, or refused, while it was still carrying this session's proposal is
    # invisible to the check above and fatal to the write below, since `proposed_workout_id`
    # is unique. Giving it up here is what turns a walk that died at the index into a walk
    # that offers the session the recording it can still answer.
    def offer(account_id, session, claimed)
      window = session[:window]
      return :already_waiting if WithingsWorkouts.standing(account_id, session[:id], window)

      pick = WithingsWorkouts.best(available(account_id, window, session[:id], claimed), window)
      return :without_activity unless pick

      claimed << pick[:id]
      WithingsAnswers.reclaim(account_id, session[:id])
      wrote?(pick[:id], session[:id]) ? :proposed : :already_waiting
    end

    # The write, guarded on both halves of what the unique index protects, and reported on by
    # what it actually did rather than by having been reached. #555.
    #
    # `proposed_workout_id: nil` is the guard on the **row**: an offer that appeared
    # underneath this one -- another run, a half-open session -- is refused rather than
    # overwritten. The `NOT EXISTS` is the guard on the **value**, which was missing: nothing
    # asked whether some other row already held this session's id, so a walk that met one
    # found out from Postgres, as an exception, out of `pair` and `WithingsBackfill.attempt`
    # and `WithingsBackfill.run`, with the year's requests already spent. After
    # `WithingsAnswers.reclaim` the only row that can still be
    # holding the slot is a live proposal written by a concurrent walk, and this declines to
    # it rather than raising at it.
    #
    # It is a narrower window and not a closed one: two transactions can both read no row and
    # both write, and the index is what catches that -- which is what the index is for, and
    # why the rescue in `WithingsBackfill.offered` stays.
    #
    # The subquery is not scoped to the account on purpose, unlike every other read in this
    # module. What it is standing in front of is a unique index over the whole table, so the
    # question it has to ask is the index's question and not this lifter's.
    #
    # And the count is read, because a write that changed nothing is not a proposal made. The
    # report's four numbers are what a lifter uses to decide whether an import worked, and
    # until now the only one of them that could not be trusted was the one they read first.
    # `:already_waiting` rather than a fourth state: every way of getting here means some
    # proposal is in place for this session or for this activity, which is what that word
    # already says, and a fourth number would need a fifth sentence on two screens to explain
    # a case that means the same thing as the third.
    def wrote?(activity_id, workout_id)
      held = DB[:withings_workouts].where(proposed_workout_id: workout_id).exists
      DB[:withings_workouts].where(id: activity_id, proposed_workout_id: nil).exclude(held)
                            .update(proposed_workout_id: workout_id).positive?
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

