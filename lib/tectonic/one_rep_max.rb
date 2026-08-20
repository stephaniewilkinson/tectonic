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
    def estimate(weight:, reps:, rpe: nil)
      return nil unless weight.to_i.positive? && reps.to_i.positive?

      rating = rpe || ANCHOR_RPE
      # A single taken to failure is not an estimate at all: the max that day is the
      # weight that was on the bar, and the chart's top row stops short of saying so.
      return weight if reps == 1 && rating >= FAILURE_RPE

      percent = SetScheme::RPE8_PERCENTS[reps + ANCHOR_RPE - rating]
      percent && (weight * 100 / percent).round
    end

    # The best max a group of sets supports, ignoring the ones the chart cannot read, or
    # nil when none of them can be read at all. The best rather than the latest, because a
    # max is the most that has been demonstrated, not the most recent thing attempted.
    def best_of(sets)
      sets.filter_map { |set| estimate(weight: set[:weight], reps: set[:reps], rpe: set[:rpe]) }.max
    end
  end
end

