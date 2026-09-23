# frozen_string_literal: true

require_relative 'db'
require_relative 'timing'
require_relative 'withings_workouts'

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

    # The proposals waiting for an answer, newest session first, each with the session it is
    # about and the sentence that explains it. Newest first because a session from last month
    # is one somebody can still remember well enough to judge, and the confident answers are
    # worth getting out of the way before the archaeology.
    def waiting(account_id)
      rows = unanswered(account_id)
      sessions = sessions_for(account_id, rows)
      stamps = stamps_for(sessions.keys)
      rows.filter_map { |row| offered(row, sessions[row[:proposed_workout_id]], stamps) }
          .sort_by { |offer| offer[:workout][:date] }.reverse
    end

    # Offered, and neither confirmed nor refused. The two answered states are excluded here
    # rather than filtered later, because a list that showed an answered proposal would invite
    # somebody to answer it again -- and the second answer would silently do nothing, since
    # `confirm` refuses a session that is already matched.
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
    def outstanding(account_id)
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil)
                            .exclude(proposed_workout_id: nil)
    end

    # Scoped by account as well as by id, so a proposal whose session somehow belongs to
    # somebody else renders as nothing at all rather than as a stranger's date.
    def sessions_for(account_id, rows)
      DB[:workouts].where(account_id:, id: rows.map { |row| row[:proposed_workout_id] }).to_hash(:id)
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

