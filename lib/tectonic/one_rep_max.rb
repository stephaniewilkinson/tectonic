# frozen_string_literal: true

require 'roda'
require_relative 'set_scheme'

class Tectonic < Roda
  # What a set that was actually lifted says about a one-rep max. There is no second
  # chart here: SetScheme's RPE-8 percentages are the whole model, read in the other
  # direction. That table says what fraction of a max a set of n reps is when it is taken
  # at RPE 8, so a set of n reps at any other rating is first restated as the RPE-8 set of
  # equal difficulty -- one rep left in reserve is one rep off the bar -- and then divided
  # back out.
  module OneRepMax
    # The rating the chart is written at, and the rating an unrated set is read as. The
    # programs this app generates write their top sets to land near an 8, so reading an
    # unrated one as an 8 is the assumption already baked into the loads.
    ANCHOR_RPE = 8
    # The rating at which a set was taken to the point of no further reps.
    FAILURE_RPE = 10
    # The restated rep count at or below which an estimate is trusted to set a number by
    # itself.
    #
    # The chart reads to ten reps, and it should: silently having no number is worse than a
    # number that says how sure it is, and the dead end that produced -- a movement trained in
    # eights with no max and a page claiming nothing had been lifted -- was the worse failure
    # of the two.
    #
    # But the instinct behind the old refusal was right. Accuracy genuinely degrades the
    # further a set sits from failure, and it degrades faster in a lifter without the
    # experience to rate honestly. So the estimate is made and marked rather than withheld:
    # above six restated reps it is reported, drawn on the chart, and **not allowed to become
    # a training max on its own**. See TrainingMax.derived.
    #
    # **Five, which is where the table used to stop, and that is the whole reason.**
    #
    # Six was the first choice and the data refused it. Setting the boundary at six lets an
    # index-six reading start setting a max where it never could before, and on this account
    # that moves five derived maxes -- Front Squat from 105 to 123, which is seventeen per cent
    # of what every percentage of it would generate against. The goal of extending the row was
    # correct estimates with *no change to any prescription*, and six quietly breaks it.
    #
    # Five keeps that promise exactly: every reading that could set a max before still can, at
    # the same number, and nothing that could not has started. The extension is therefore
    # visible only where it was wanted -- in what the app can report and draw.
    #
    # Six is defensible on its own terms and is one character away. It is a decision about
    # whether a set six reps from a single should price a training block, which is a coaching
    # question rather than an arithmetic one, so it is not one to make as a side effect.
    CONFIDENT_REPS = 5

    module_function

    # The max a single set implies, in whole pounds, or nil when the chart has nothing to
    # say about it. A set of 8 at any rating, or of 5 at an easy 6, restates to a rep
    # count the chart does not cover, and an estimate off work that light is a guess
    # dressed as a number, so it declines to make one.
    #
    # `planned_rpe` is the effort the block asked this set to be taken at, and it is read
    # where the lifter did not say (#294). See `rating_for`.
    def estimate(weight:, reps:, rpe: nil, planned_rpe: nil)
      return nil unless weight.to_i.positive? && reps.to_i.positive?

      rating = rating_for(rpe, planned_rpe)
      # A single taken to failure is not an estimate at all: the max that day is the
      # weight that was on the bar, and the chart's top row stops short of saying so.
      return weight if reps == 1 && rating >= FAILURE_RPE

      percent = SetScheme::RPE8_PERCENTS[reps + ANCHOR_RPE - rating]
      percent && (weight * 100 / percent).round
    end

    # What rating to read a set at: the one the lifter gave, else the one the block asked
    # for, else the anchor. #294.
    #
    # The anchor was the only fallback, and ANCHOR_RPE's own note gives the reason -- "the
    # programs this app generates write their top sets to land near an 8". That is true of a
    # `linear` lift, whose top weight is stepped to land there. **It is false of a `percent`
    # lift**, whose intensity is authored on the lift row: a top set written at 70% of max is
    # nowhere near an 8, and reading it as one estimates a max off a set that was deliberately
    # easy. The inflated max then prices the next week's percentages, which is a loop.
    #
    # Since #265 the generator copies the prescription's own answer onto the row, so the
    # better assumption is now sitting there. A set the lifter rated is still read at what
    # they said -- an actual answer outranks the question -- and a set with neither still
    # falls back to the anchor, which is every set logged by hand and every one written
    # before #265.
    #
    # Worth being plain that this is still an assumption. A set prescribed at RPE 8 and
    # taken at 9 is read as an 8 until somebody taps a rating, and the estimate is low by
    # that much. Reading it at the target is the closer guess of the two available, not a
    # measurement, and #293 is where the app says which sets it had to guess about.
    def rating_for(rpe, planned_rpe)
      rpe || planned_rpe || ANCHOR_RPE
    end

    # The best max a group of sets supports, ignoring the ones the chart cannot read, or
    # nil when none of them can be read at all. The best rather than the latest, because a
    # max is the most that has been demonstrated, not the most recent thing attempted.
    def best_of(sets)
      best_reading(sets)&.fetch(:pounds)
    end

    # The same answer with the set that produced it, so a reader can say *when*. #293.
    #
    # "The best rather than the latest" is the right rule and it is also the one that makes
    # a bare number misleading: there is no lower bound on the window, so the number can be
    # a single lifted three years ago and nothing about it says so. The date is what turns
    # that from a hidden property into a fact somebody can judge -- which is the whole of
    # #293, and why nothing here expires or decays anything.
    #
    # Nil rather than a zero-ish reading when no set can be read, so every caller keeps the
    # "nothing to go on" branch it already had.
    def best_reading(sets)
      readings(sets).max_by { |reading| reading[:pounds] }
    end

    # The best reading the chart is sure enough of to let stand on its own. Nil where every
    # set it can read is further from a single than CONFIDENT_REPS.
    #
    # A separate method rather than a flag on the one above, because the two answer different
    # questions and both are wanted at once: the chart draws the best estimate there is, and
    # the training max takes the best one that may set a number by itself. A movement trained
    # in eights has the first and not the second, and that is the state the page now describes
    # rather than the one it used to deny.
    def best_confident_reading(sets)
      readings(sets).select { |reading| reading[:confident] }.max_by { |reading| reading[:pounds] }
    end

    def readings(sets)
      sets.filter_map { |set| reading_of(set) }
    end

    # One set as an estimate and the day it was lifted, or nil where the chart declines.
    # `date` rides along from the row; it is nil on any caller that did not select it, which
    # reads as "no date" rather than raising.
    def reading_of(set)
      pounds = estimate(weight: set[:weight], reps: set[:reps], rpe: set[:rpe], planned_rpe: set[:planned_rpe])
      return nil unless pounds

      restated = restated_reps(set)
      { pounds:, on: set[:date], from_reps: restated, confident: restated <= CONFIDENT_REPS }
    end

    # The rep count this set restates to at RPE 8, which is the row of the chart it was
    # actually read from and therefore the thing confidence is a property of. A set of eight
    # at RPE 7 is read as nine reps, and it is the nine that makes it a guess rather than the
    # eight.
    def restated_reps(set)
      set[:reps] + ANCHOR_RPE - rating_for(set[:rpe], set[:planned_rpe])
    end
  end
end

