# frozen_string_literal: true

require_relative 'db'
require_relative 'sets'
require_relative 'timing'
require_relative 'workouts'

class Tectonic < Roda
  # What one lifter usually takes between sets of one movement. #281, moved out of app.rb by
  # #408 when it acquired a second caller.
  #
  # The rest timer wants this for the set a tap just finished. The session-length estimate
  # wants it for every unlifted set on the page, and the generation-time budget check wants it
  # for a day that has not been written yet -- and that last one is outside the web app
  # entirely, which is what made a private method on a Roda instance the wrong home for it.
  #
  # Two copies of this query would have been the real cost. The number it produces is the
  # fallback the rest timer counts down and the fallback the estimate prices a set with, and
  # those two disagreeing about the same set would put a timer showing 90 seconds under a page
  # that had budgeted 150 for it.
  module Turnarounds
    # How many of a movement's own turnarounds to read before taking the middle one.
    #
    # A bound rather than the whole history, because this runs inside a Done tap and a lifter
    # three years in has thousands of squat sets -- and the median of the last sixty is the
    # number wanted anyway. What somebody took between sets in 2023 is not what they take now,
    # and letting it vote would make the suggestion drift towards a lifter who no longer
    # exists. Sixty is roughly the last ten sessions of a movement trained in sixes.
    SAMPLE = 60

    module_function

    # The median turnaround, or nil where there is not enough of this lifter's own history to
    # say. Nil rather than a number is the whole of the honesty here: the app offers a
    # measurement or it offers nothing, and "rest 3 minutes before a heavy single" is a
    # coaching opinion that #263 settled belongs to the assistant.
    #
    # Scoped through the account's own workouts rather than by exercise alone, since the
    # library movements are shared -- without it a first squat session would be offered the
    # median turnaround of every lifter on the instance.
    def median_for(account_id, exercise_id, sample: SAMPLE)
      return nil unless exercise_id

      rows = WorkoutSet.where(exercise_id:, is_completed: true)
                       .exclude(completed_at: nil)
                       .where(workout_id: Workout.where(account_id:).select(:id))
                       .order(Sequel.desc(:id))
                       .limit(sample)
                       .select(:workout_id, :completed_at)
                       .all.map(&:values)
      Timing.between_sets_of(rows)
    end

    # The same answer as a callable that asks once per movement, which is the shape both
    # estimating callers want: a five-movement session asks five questions rather than one a
    # set, and asks them again on every Done tap without the cache.
    #
    # `fetch` with a block rather than `||=`, because nil is the answer for a movement with no
    # history and `||=` would ask the database again on every set of it -- precisely the
    # session where the lookup is most useless and most repeated.
    #
    # The cache belongs to the returned lambda rather than to this module, so it lives exactly
    # as long as whoever asked for it. A module-level cache would be shared between accounts
    # on one process, which for a number derived from one lifter's own sessions is not a
    # performance decision but a leak.
    def lookup(account_id)
      seen = {}
      ->(exercise_id) { seen.fetch(exercise_id) { seen[exercise_id] = median_for(account_id, exercise_id) } }
    end
  end
end

