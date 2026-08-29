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
      sets.filter_map { |set| reading_of(set) }.max_by { |reading| reading[:pounds] }
    end

    # One set as an estimate and the day it was lifted, or nil where the chart declines.
    # `date` rides along from the row; it is nil on any caller that did not select it, which
    # reads as "no date" rather than raising.
    def reading_of(set)
      pounds = estimate(weight: set[:weight], reps: set[:reps], rpe: set[:rpe], planned_rpe: set[:planned_rpe])
      pounds && { pounds:, on: set[:date] }
    end
  end
end

