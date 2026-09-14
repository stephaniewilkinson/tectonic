# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'program_days'
require_relative 'program_generator'
require_relative 'workouts'

class Tectonic < Roda
  # Changing the rack reaches the sessions the rack already wrote. #439.
  #
  # The plate math was not the bug. #369 taught the generator to enumerate a dumbbell the way
  # #140 taught it to enumerate a bar, and on the reporting account's inventory -- a 4 lb
  # handle with pairs of 10, 5 and 2.5 -- `Equipment#dumbbell_totals` is exactly
  # [4, 9, 14, ... 79], so every loadable dumbbell ends in 4 or 9 and `loadable(45)` is 44.
  # That is the issue's own arithmetic, and the code already agreed with it.
  #
  # What was wrong is that the answer never reached the sessions already written. The same
  # movement at the same prescribed 45 sits in the block as 44 on one week and 45 on the next,
  # and the difference is nothing about the plan: the 44 was generated after the inventory was
  # filled in and the 45 before it. A rack is not a property of a session, it is a property of
  # the lifter, and the sessions kept whichever answer happened to be current on the day they
  # were generated.
  #
  # **This is #407's shape with a different trigger.** That one was about editing a
  # prescription -- the plan changed and the session it had produced did not. This is the same
  # gap reached from the other side: the prescription is untouched and the *answer* to it has
  # changed, because what the lifter can load has. So it uses the same machinery, and gets the
  # same guarantee out of it: `refresh` never touches a completed set, so a rack described
  # after a session was trained cannot rewrite what was lifted in it.
  #
  # **From today forward, and no further back.** A past session is a record even where its sets
  # were never ticked -- it says what the plan was on the day, and re-rounding it would be the
  # app revising history to match equipment bought afterwards. Today is included because a
  # session being trained now is exactly the one a lifter has just walked over to the rack and
  # corrected the settings for.
  module RackChange
    module_function

    # Re-rounds every upcoming generated session, and reports how many actually moved.
    #
    # The count is of sessions whose weights changed rather than of sessions rewritten, and the
    # difference matters because `refresh` rewrites unconditionally -- it deletes the
    # unfinished rows and writes them again from the plan, so a rack change that alters
    # nothing would still report every session in the block as touched. #441 is the whole
    # argument for caring: a count that says "12 sessions updated" when none of them moved is
    # the same kind of untruth as a session reporting itself left alone while being emptied.
    def reround(account_id, today: Date.today)
      upcoming(account_id, today).count { |day| moved?(day) }
    end

    # The program days that have already produced a session dated today or later.
    #
    # Reached through the workouts rather than through the programs, because a day only has a
    # session to re-round if generation has actually happened for it -- an unwritten week is
    # not stale, it is simply not there yet, and it will be generated against the new rack
    # whenever it is asked for.
    def upcoming(account_id, today)
      days = Workout.where(account_id:).exclude(program_day_id: nil)
                    .where { date >= today }.select_map(:program_day_id).uniq
      ProgramDay.where(id: days).all
    end

    # One day rewritten, and whether that made any difference to what is on the bar.
    #
    # Compared by the weights alone, in order. A rewrite replaces the unfinished rows with new
    # ones, so their ids differ even where every weight is identical -- comparing rows, or
    # anything carrying an id, would report a change on every session every time and make the
    # count meaningless. The weights in order are also the thing a lifter would actually
    # notice, which is what makes them the right thing to count rather than merely the
    # convenient one.
    def moved?(day)
      workout = Workout.where(program_day_id: day.id).first
      return false unless workout

      before = weights(workout)
      ProgramGenerator.new(day.program_week.program).refresh(day)
      weights(workout) != before
    end

    def weights(workout)
      WorkoutSet.where(workout_id: workout.id).order(:id).select_map(:weight)
    end
  end
end

