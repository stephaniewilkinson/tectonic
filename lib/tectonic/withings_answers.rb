# frozen_string_literal: true

require_relative 'db'
require_relative 'withings_workouts'

class Tectonic < Roda
  # The lifter's answers to a proposed match -- yes, no, and the bookkeeping each one owes the
  # questions still open about the same session. #605.
  #
  # Out of WithingsWorkouts because they are writes about answers, and that module is the
  # question: which activity to offer, and why. Every rule about what an answer does to the
  # other open questions -- #555's withdraw and reclaim -- lives here, in one place, so that
  # the two ways of answering cannot come to disagree about it.
  module WithingsAnswers
    module_function

    # The lifter saying yes. Scoped to the account, and refused where either side has already
    # been answered -- a second confirmation arriving from a stale page must not move a match
    # that is already made, and the unique index on `workout_id` would make it an exception
    # rather than a no-op if it tried.
    # How many rows it linked -- one, or none where there was nothing left to link. A count
    # rather than a flag because "nothing happened" and "it was refused" are the same answer
    # here and a boolean would invite a caller to treat them as different.
    #
    # **And every other question about this session is withdrawn in the same breath**, which
    # is the first half of #555. A session can carry a proposal from a backfill *and* be
    # matched from its own record page to a second recording of the same afternoon -- a phone
    # listening as well as the watch, an activity split in two in the Withings app -- and
    # until now the backfill's row was left exactly as it was: unclaimed, un-refused, still
    # naming a session that had had its answer for months. It went on being counted as a
    # question on the workouts list and in settings, it went on being listed at
    # /workouts/withings, and the only control offered for it was a Yes that landed here and
    # was refused. A question about a session is answered when the session is answered, by
    # whichever activity, and the column that carries the question has to say so.
    #
    # In one transaction with the link, because the two writes are one answer: a crash between
    # them would leave precisely the state this exists to end.
    def confirm(account_id:, workout_id:, external_id:)
      DB.transaction do
        answered = WithingsWorkouts.matched(workout_id)
        linked = answered ? 0 : link(account_id, workout_id, external_id)
        withdraw(account_id, workout_id) if answered || linked.positive?
        linked
      end
    end

    # The link itself, on the terms above: this account's activity, and only one that has not
    # already been claimed or refused.
    def link(account_id, workout_id, external_id)
      DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil, dismissed_at: nil)
                            .update(workout_id:)
    end

    # Every open question about this session, withdrawn, because the session now has an answer.
    #
    # Only the rows that are still questions: the activity that was just claimed or refused
    # excludes itself, since the answer was written first and this filters on the two columns
    # that carry it. That is deliberate rather than incidental -- an activity the lifter
    # confirmed keeps the record that a backfill proposed it, and what goes is the promise
    # nobody can keep.
    #
    # Called on a yes that linked nothing as well as on one that linked a row, which is the
    # stale-page case #555 is about: the session was answered from somewhere else while the
    # queue was on screen, so the tap is not a match to make but a question to close. There is
    # no third possibility to worry about -- a yes naming an activity that no longer exists,
    # against a session with no answer at all, leaves the session's question standing, which
    # is right, because nothing has answered it.
    def withdraw(account_id, workout_id)
      DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id,
                                   workout_id: nil, dismissed_at: nil)
                            .update(proposed_workout_id: nil)
    end

    # The other direction: a proposal about a session that is *still* asking, held by an
    # activity that has since been claimed by another session or refused outright. #555.
    #
    # `proposed_workout_id` is unique, so that dead proposal holds the session's only slot.
    # Nothing could ever fill it -- the activity is answered, so `WithingsWorkouts.standing` cannot see it and
    # the backfill believes the session has no proposal at all -- and the next run that picks
    # a second activity for that session sent its `UPDATE` straight into the index. From the
    # rake task that was a stack trace after the year's requests were spent; from the import
    # button (#558) it was a 500 on the settings page of somebody who had just pressed it.
    #
    # Cured here, at the write that wants the slot, rather than at every answer that can
    # strand one. Two reasons, and the second is the stronger. Rows stranded before this
    # shipped exist already and no future answer will ever visit them, so the cure has to live
    # somewhere a later run passes anyway; and a state cured in two places is a state cured
    # two slightly different ways, which is how `WithingsWorkouts.standing` and `.candidates` came to disagree
    # in #560.
    def reclaim(account_id, workout_id)
      DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id)
                            .exclude(workout_id: nil, dismissed_at: nil)
                            .update(proposed_workout_id: nil)
    end

    # The lifter saying no, which #520 requires to stick per workout and permanently.
    #
    # Two writes, because "no" means two things at once and only one of them has an activity
    # to hang on. The session is marked asked-and-answered, which is what silences the prompt
    # even for a session Withings will never have anything for. And the activity that was on
    # screen, where there was one, is set aside too: it was offered *because* it overlaps this
    # session, so a lifter saying it is not this session is saying it is not a lift they
    # logged -- and offering it to the session half an hour either side would be the same nag
    # wearing a different session's clothes.
    #
    # The row survives both. Withings will send it again on the next fetch, and a delete
    # would simply let it come back and be proposed afresh.
    #
    # Three writes since #555, and the third is the same one `confirm` makes: a no is an
    # answer about the session, so every open question about it is withdrawn too. Ordinarily
    # that is the row on the next line and the two writes agree; where they do not -- a
    # backfill proposed one activity and the page the lifter pressed No on was offering
    # another -- the difference is exactly a question left standing about a session that has
    # said it does not want to be asked.
    def dismiss(account_id:, workout_id:, external_id: nil)
      now = Time.now
      DB.transaction do
        DB[:workouts].where(id: workout_id, account_id:).update(withings_dismissed_at: now)
        withdraw(account_id, workout_id)
        next if external_id.to_s.empty?

        DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil)
                              .update(dismissed_at: now)
      end
    end
  end
end

