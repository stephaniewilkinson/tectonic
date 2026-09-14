# frozen_string_literal: true

require_relative 'db'
require_relative 'error_reporting'
require_relative 'sets'
require_relative 'workouts'

class Tectonic < Roda
  # Something closes a session. #410, the first half.
  #
  # Sessions stayed open until somebody said otherwise, and the log shows what that cost:
  # workout 28 reported **24h 46m**, because the first set was marked late one evening and
  # the rest the next morning. Several sessions sit at `performed` with a handful of sets done
  # and no ending at all, so there is no way to tell "stopped here" from "still going".
  #
  # The finish control itself has existed since #218 and `finished_at` is already the honest
  # end of a session. What was missing is anything that reaches for it on the lifter's behalf.
  #
  # ## Two thresholds, and they are different kinds of number
  #
  # **The nudge** is a question, so it can afford to be wrong. Asking "still going?" twenty
  # minutes into a chat costs one tap.
  #
  # **The automatic close** is a write, so it cannot. It only fires long after any session
  # could still be running, because the failure it risks is stamping an end onto a session
  # somebody is in the middle of -- and the cost of waiting is that the record is untidy for
  # an afternoon, which is what it already was.
  #
  # ## When the answer arrives is not when the session ended
  #
  # Both paths stamp the **last completed set**, never the moment of answering. A prompt seen
  # an hour later, or a sweep that runs the next morning, must not add that hour to how long
  # the session took -- which is the reading #410 exists to fix, so producing a new version of
  # it would be a poor joke.
  #
  # The finish *button* keeps stamping the current time and is right to. Tapping it is a
  # lifter standing in the gym saying they are done, and the ten minutes spent putting plates
  # away is time the session cost. Answering a nudge is not that.
  module SessionClose
    # How long a session has to go quiet before it is worth asking. The floor and the ceiling
    # are the twenty-to-thirty minutes #410 calls reasonable.
    QUIET_FLOOR = 15 * 60
    QUIET_CEILING = 30 * 60
    # "Three times the prescribed rest for the lift you are on", from #410, clamped between
    # the two.
    #
    # Worth being plain about what the multiple does and does not do: at an ordinary
    # three-minute rest it comes to nine minutes, which the floor raises to fifteen, so for
    # most sessions this *is* the fixed number. It earns its place at the top of the range --
    # a block writing eight minutes between heavy singles gets the full half hour rather than
    # being asked whether it is still going while the lifter is still resting. That is the
    # direction the prescription can actually improve on a constant.
    RESTS = 3
    # When nobody answered and nobody came back. Six hours is not a guess about how long a
    # session lasts; it is a length of time after which no reading of the rows has the lifter
    # still in the gym. The nudge is what handles the ordinary case, and this only catches the
    # sessions where the phone was closed and the question never seen.
    ABANDONED_AFTER = 6 * 60 * 60

    module_function

    # How long this session should be left alone before it is asked about, taken from the
    # rest prescribed for the last set that was actually ticked off -- which is "the lift you
    # are on" in the only sense the rows can answer.
    def quiet_after(sets)
      prescribed = last_done(sets)&.[](:planned_rest_seconds)
      return QUIET_CEILING unless prescribed

      (prescribed * RESTS).clamp(QUIET_FLOOR, QUIET_CEILING)
    end

    # The instant this session last did anything, which is the end it would be stamped with.
    # Nil on a session with nothing lifted: there is no ending to reach for, and inventing one
    # would close a session that never opened.
    def ends_at(sets) = last_done(sets)&.[](:completed_at)

    def last_done(sets)
      sets.select { |set| set[:is_completed] && set[:completed_at] }
          .max_by { |set| set[:completed_at] }
    end

    # Closes every session of this account that has been quiet long enough to be over,
    # stamping each with its own last completed set.
    #
    # A command answering nothing, and lazy, for ProgramSchedule's reasons exactly: a cron job
    # needs a scheduler this app does not have, and a session nobody ever looks at is a
    # session whose untidy ending nobody ever reads. Called from the same two places -- the
    # way in, and the calendar.
    #
    # Nothing here may raise into a request. Somebody arriving has come to look at their
    # training, and a failure to tidy up somebody's records must not turn the front page into
    # a 500 on the way past.
    def sweep(account_id, now = Time.now)
      abandoned(account_id, now).each { |id, last| Workout.where(id:).update(finished_at: last) }
      nil
    rescue StandardError => e
      ErrorReporting.note('session_close', account_id:)
      report(e)
      nil
    end

    # Open sessions whose last completed set is long enough ago, as workout id => that stamp.
    #
    # One grouped query rather than a walk, because this runs on the way into every page. The
    # join through the account's own workouts is what keeps it to this lifter; `finished_at:
    # nil` is what keeps it to sessions nobody has closed; and requiring a completed set at
    # all is what keeps it off the planned sessions sitting in next week, which have no
    # ending because they have no beginning.
    def abandoned(account_id, now)
      WorkoutSet.where(is_completed: true).exclude(completed_at: nil)
                .where(workout_id: Workout.where(account_id:, finished_at: nil).select(:id))
                .group(:workout_id)
                .having { max(:completed_at) < (now - ABANDONED_AFTER) }
                # Aliased, because select_hash needs a name to read the value column back
                # under and a bare function expression has none. Without the alias this
                # raises -- and `sweep` rescues everything so it can never reach a request,
                # which meant the failure was completely silent until a spec asked whether
                # anything had actually been closed.
                .select_hash(:workout_id, Sequel.function(:max, :completed_at).as(:last_at))
    end

    def report(exception)
      return unless ErrorReporting.on?

      Sentry.capture_exception(exception)
    rescue StandardError
      # Reporting a failure must never become a second one, on the request path least of all.
    end
  end
end

