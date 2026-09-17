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
    # **Six**, which is #448's number and #461's decision.
    #
    # It shipped at five first, and the argument for five was that five is where the table
    # used to stop -- so every reading that could set a max still could, at the same number,
    # and the extended row was visible only in what the app reports and draws. That is a real
    # property and it was the right thing to hold while the question was open. It is not a
    # reason on its own: it makes the boundary an artefact of the table's old length rather
    # than a claim about how far from a single a set may sit and still price a block.
    #
    # Six is that claim, and it is the ordinary one. A set of six at RPE 8 is two reps from
    # failure and sits well inside the range the RTS chart was built from; the accuracy
    # argument against high-rep estimates bites past eight or nine rather than here. Holding
    # at five meant a lifter training fives at RPE 7 -- a normal, conservative way to train,
    # and restating to six -- never got a derived max at all, which is the population this was
    # built for.
    #
    # **What it moved, checked against production rather than reasoned about.** Two derived
    # maxes, both on movements with no stated max to protect them: Front Squat 105 to 123, and
    # Decline Bench 126 to 130. Nothing with a stated max moves, because a stated max is not
    # derived from a reading at all. An earlier note here said five maxes moved; that counted
    # the stated ones, which do not.
    #
    # The Front Squat jump is the one to understand before trusting this. 105 came from the
    # heaviest set within five restated reps and 123 from a set of five at RPE 7, which is
    # six restated -- the same training, read one row further down a chart that reaches it.
    # Seventeen per cent is a large correction, and it is large because the old boundary was
    # excluding the best evidence the movement had rather than because the new one invents
    # any.
    CONFIDENT_REPS = 6

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
    # easy.
    #
    # **That reads the max low, not high**, and this comment said the opposite until #486
    # worked the arithmetic. Calling an easy set an 8 claims it was two reps from failure when
    # five were left, which is a claim that the lifter is weaker than they are. A 140 lb set of
    # five -- 70% of a 200 lb max -- restates to 5 reps at 81.1% and gives 173; read at the 5
    # it actually was, it restates to 8 reps at 73.9% and gives 189.
    #
    # It is still a loop and that is still the reason to fix it, just a descending one: a
    # deflated max prices the next week's percentages lower, the sets get easier, and the
    # estimate has no way back up. Worth naming the direction, because the two spiral in
    # opposite directions and the fix only looks obvious once you know which way this goes.
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
      # The set itself rides along with the number it produced. #449: a proposal of 127 means
      # nothing on its own, and "100 lb x 5 at RPE 7, which is 6 reps from a single" can be
      # argued with -- which is the difference between a tool that reports and one that is
      # merely believed. The date has travelled here since #293 for the same reason.
      #
      # `rating` rather than the raw rpe, because the rating is what was actually read: an
      # unrated set is read at its planned effort, else at the anchor, and a reader shown the
      # nil would have no idea which of the three produced the number.
      { pounds:, on: set[:date], from_reps: restated, confident: restated <= CONFIDENT_REPS,
        weight: set[:weight], reps: set[:reps], rating: rating_for(set[:rpe], set[:planned_rpe]) }
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

