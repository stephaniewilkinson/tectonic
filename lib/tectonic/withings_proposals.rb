# frozen_string_literal: true

require_relative 'db'
require_relative 'timing'
require_relative 'withings_workouts'
# For the sessions themselves, which are model rows here rather than hashes since #572 --
# see `sessions_for` for what that buys and what it costs.
require_relative 'workouts'

class Tectonic < Roda
  # Every proposal a backfill has left, read back for the one screen that lists them.
  #
  # ## Why this is a screen at all
  #
  # #520 put the question on the workout record, and for the forward flow that is right: the
  # proposal arrives one at a time, on a page the lifter is already looking at, about the
  # session they have just finished. The backfill breaks the assumption under that. A first
  # run over a few years can leave eighty proposals at once, and eighty answers given one
  # record page at a time means finding eighty days in a list ordered by date that says
  # nothing about which days carry a question. That is a job nobody gets to the end of -- and
  # a half-answered backfill is worse than none, because the proposals nobody looked at are
  # indistinguishable from the ones somebody decided about.
  #
  # ## Why it is a third module rather than more of the other two
  #
  # `WithingsWorkouts` is the matcher: it fetches, stores, scores and answers what a record
  # page should say. `WithingsBackfill` is the walk: years, pages, pauses and a watermark.
  # This is neither -- it is a read over rows both of those have already settled, and it
  # depends on them in one direction only. That is also what keeps it honest about the thing
  # this screen must never do: **it asks Withings nothing**. A review page that fetched would
  # be one page view standing on a hundred API calls, which is the surest way to be
  # rate-limited by the provider whose rate limit is the one failure this app cannot see.
  module WithingsProposals
    module_function

    # The proposals waiting for an answer, most recently *trained* session first, each with the
    # session it is about and the sentence that explains it. Newest first because a session
    # from last month is one somebody can still remember well enough to judge, and the
    # confident answers are worth getting out of the way before the archaeology.
    #
    # ## Trained rather than planned, and why the order had to move with the date
    #
    # This sorted on `workouts.date` until #572, which is the day a session was *written for*.
    # For a generated block that is a decision made weeks ahead, and the reporting account
    # trains up to three days away from it -- so the queue was ordered by a column that is not
    # a record of anything that happened, and the sentence beside each row asks the lifter to
    # remember something that did. The date printed on the row moved to
    # `Workout#performed_or_planned_on` in the same change, and these two could not have been
    # separated: a list labelled with one date and sorted by another is worse than one that is
    # merely wrong, because the rows then sit in an order nothing on the screen accounts for --
    # the 23rd above the 24th, with no way to tell it from a bug in the list.
    #
    # **The order the questions arrive in therefore changed**, and that is the point rather
    # than a consequence to be apologised for. The argument for newest-first is an argument
    # about memory, and memory is of training: what a lifter can answer quickly is the session
    # they actually did on Wednesday, not the one a programme had pencilled in for Friday. A
    # queue ordered by the plan interleaves recent training with old training wherever
    # anybody trained off-plan, which is exactly where the questions are hardest.
    #
    # Sorted here rather than in SQL because the date is a reading of two columns rather than
    # one -- `performed_on` where there is one and the plan where there is not -- and the rows
    # are already all in hand and already filtered by `offered`. An ORDER BY that reproduced
    # the fallback would be a second spelling of the rule, free to drift from the method every
    # screen dates a session with.
    def waiting(account_id)
      rows = unanswered(account_id)
      sessions = sessions_for(account_id, rows)
      stamps = stamps_for(sessions.keys)
      rows.filter_map { |row| offered(row, sessions[row[:proposed_workout_id]], stamps) }
          .sort_by { |offer| offer[:workout].performed_or_planned_on }.reverse
    end

    # Offered, and neither confirmed nor refused. The two answered states are excluded here
    # rather than filtered later, because a list that showed an answered proposal would invite
    # somebody to answer it again -- and the second answer would silently do nothing, since
    # `confirm` refuses a session that is already matched.
    #
    # **That last clause was the bug rather than the reassurance**, and #555 is what it cost.
    # It reads the two answered states off the *activity* and says nothing whatever about the
    # session, so a proposal naming a session that was matched to some other recording was
    # neither confirmed nor refused, appeared here, and offered a Yes that `confirm` then
    # refused for exactly the reason quoted -- a row the lifter could tap for ever without
    # changing anything. A proposal has two ends and either of them being answered ends the
    # question; `outstanding` now reads both, which is what makes the sentence above true
    # instead of merely confident.
    def unanswered(account_id) = outstanding(account_id).all

    # How many questions are still open, which is what a doorway to this screen needs to know
    # before it can decide whether to exist. #534.
    #
    # A count rather than `waiting(account_id).length`, and the difference is not tidiness.
    # `waiting` loads every proposal, then every session behind them, then every set stamp of
    # every one of those sessions, and reduces the lot to sentences -- three queries and a
    # timing calculation per row, to answer a question whose answer is a number. Asking it
    # that way from the workouts list would make browsing training pay for a screen the lifter
    # has not opened.
    #
    # `except` is for the record page, which asks a narrower question: not "how many are
    # waiting" but "how many are waiting *besides the one I am looking at*". Without it the
    # prompt on a backfilled session would count itself and tell a lifter with one question
    # left that there was one elsewhere. A session in the forward flow is not in this set at
    # all -- its activity has no `proposed_workout_id`, because nothing wrote one down -- so
    # passing its id is simply a no-op there rather than a special case to remember.
    def waiting_count(account_id, except: nil)
      rows = outstanding(account_id)
      rows = rows.exclude(proposed_workout_id: except) if except
      rows.count
    end

    # The one spelling of "still a question", as a dataset rather than as rows, so that the
    # list and the count cannot come to disagree about what counts as waiting. Two spellings
    # would drift on exactly the case that is hardest to notice: a badge saying three while
    # the screen behind it lists two, which reads as a bug in the screen rather than in the
    # badge and sends somebody looking in the wrong place.
    #
    # These three conditions are also written into an index in 044, and Postgres will only
    # reach for it where it can prove this predicate implies that one. So this is not merely
    # where the filter is kept tidy -- it is the thing the index is matched against, and a
    # condition added here that is not there turns the count back into a scan of every
    # activity the account owns, silently and with every spec still passing.
    #
    # ## The fourth condition, and why it is safe to add to a predicate the index defines
    #
    # The three above ask whether the *activity* has been answered and never whether the
    # session it names has. #555: a backfill proposes an activity to a session, the lifter
    # matches that session to a second recording from its own record page, and the proposal is
    # left unclaimed, un-refused and pointing at a question that was settled months ago. It
    # was counted on the workouts list, counted beside the connection in settings, and listed
    # here with a Yes on it that `confirm` refuses every time it is pressed.
    #
    # So a proposal whose session already belongs to some activity is not waiting for
    # anything, and the exclusion says so. Adding a condition *narrows* what this returns,
    # which is the direction the index tolerates: the predicate above still implies 044's, and
    # Postgres applies this one to the handful of rows that survive it. Dropping one of the
    # three would be the change that silently costs a scan.
    #
    # It is also the second half of a pair. `WithingsWorkouts.confirm` withdraws these at the
    # moment the session is answered, so nothing new arrives in this state; this is what keeps
    # the queue honest about the rows stranded before that shipped, which no answer will ever
    # visit again. A filter and a cure rather than one or the other, because the filter alone
    # leaves a dead row holding a unique slot and the cure alone cannot reach into the past.
    def outstanding(account_id)
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil)
                            .exclude(proposed_workout_id: nil)
                            .exclude(proposed_workout_id: matched_sessions(account_id))
    end

    # The sessions this account has already matched to something. Scoped to the account like
    # everything else here, though `withings_workouts.workout_id` is unique across the table
    # and a session belongs to one lifter: the scope costs nothing, keeps the subquery on the
    # same index as its parent, and means a reader does not have to prove the cross-account
    # case is impossible before believing the line.
    def matched_sessions(account_id)
      DB[:withings_workouts].where(account_id:).exclude(workout_id: nil).select(:workout_id)
    end

    # Scoped by account as well as by id, so a proposal whose session somehow belongs to
    # somebody else renders as nothing at all rather than as a stranger's date.
    #
    # ## Model rows, and `with_performed_on` in the same breath
    #
    # These were plain `DB[:workouts]` hashes until #572, which is what left this screen the
    # last one in the app dating a session by the day it was written for: a hash has no
    # `performed_or_planned_on` to call, so the list and the template had no way to ask the
    # question every other page asks. `Workout` rows have it, and that is the whole reason
    # they are worth the model layer here -- the rule is written once, on the method, and this
    # screen reads it rather than restating it.
    #
    # `with_performed_on` is not optional decoration on that. `performed_on` answers from the
    # row where the query selected it and otherwise goes and fetches the stamp itself, one
    # session at a time -- so the same fallback that is harmless on a record page is an N+1
    # here, where there is a row per proposal and a date on every one of them. It was already
    # sprung once, in exercise history, at a hundred queries on a large account with nothing
    # failing to say so. The extra column is a correlated subquery on a query this screen was
    # making anyway, so eighty proposals cost exactly what one does, and
    # spec/dating_a_session_by_when_it_happened_spec.rb counts to make sure they still do.
    #
    # It is `min(completed_at)` twice over on the face of it -- once here and once inside
    # `stamps_for`, which loads every stamp of every one of these sessions for the interval
    # arithmetic. That is deliberate rather than overlooked: the two answers are wanted in
    # different shapes, one as a column on the row and one as a list to measure a window from,
    # and deriving the date from the stamps instead would be this module computing
    # `performed_or_planned_on` for itself -- a second spelling of the rule, on the one screen
    # whose whole bug was having its own reading of the date.
    def sessions_for(account_id, rows)
      Workout.where(account_id:, id: rows.map { |row| row[:proposed_workout_id] })
             .with_performed_on.to_hash(:id)
    end

    # One row of the list, or nil where it cannot be rendered honestly. A session whose sets
    # have lost their stamps has no interval, so there is no "overlaps for 48 of 52 minutes"
    # to be had -- and a proposal shown without its evidence is a silent match with a button
    # on it, which is the thing #520 refuses outright.
    #
    # The sentence is `because`, the forward flow's own, so the record page and this list
    # cannot come to word the same evidence two different ways.
    def offered(row, workout, stamps)
      return nil unless workout

      window = WithingsWorkouts.interval(Timing.session(workout, stamps.fetch(workout[:id], [])))
      window && { workout:, activity: row, because: WithingsWorkouts.because(row, window) }
    end

    # The stamps for a set of sessions in one query rather than one query per session, which
    # this list and the backfill's pairing both want. A hundred round trips to ask the same
    # question of a hundred sessions is how a page that should render in milliseconds takes a
    # second, and it is the shape `@stated_maxes` on the exercises list already avoids.
    def stamps_for(ids)
      return {} if ids.empty?

      DB[:sets].where(workout_id: ids)
               .select(:workout_id, :completed_at, :is_completed, :duration_seconds)
               .all.group_by { |row| row[:workout_id] }
    end
  end
end

