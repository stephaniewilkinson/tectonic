# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # Warmup ramps, from the empty bar up to just under the working weight.
  #
  # ## The ramp scales to the bar, not to the number
  #
  # This used to pick from a table of absolute thresholds -- 136 lb and 96 lb -- and #451 is
  # what is wrong with that. How much ramp a lift needs is how far it is from the empty bar,
  # which is a ratio, and the table could barely tell a 150 from a 235:
  #
  #     Deadlift    top 150   3.3x the bar   45, 95, 112, 132   four stops
  #     Back Squat  top 152   3.4x the bar   45, 92, 115, 132   four stops
  #     Front Squat top 115   2.6x the bar   45, 80, 100        three stops
  #
  # A 150 is three times the bar and wants about three stops; a 235 is over five times it and
  # genuinely wants five. Against a 45-minute cap, each unnecessary rung across two or three
  # barbell movements costs five to eight minutes, which is most of a session's slack.
  #
  # It also means the answer follows the lifter's own bar. On a 35 lb bar a 150 lb top is 4.3x
  # and gets another rung, which the old thresholds could not express at all -- they were
  # written as though every rack had a 45 in it.
  #
  # ## The numbers here are convention, and the column exists because of that
  #
  # #451 is careful about the evidence and it is right to be. That warming up helps is well
  # supported; how many sets and which rep counts is coaching convention with no trial behind
  # it. So none of the constants below is a truth -- they are a defensible default, and a lift
  # that disagrees says so through `program_lifts.warmup_sets` (040), including by saying zero.
  module Warmup
    BAR_WEIGHT = 45
    BAR_REPS = 5

    # Where the last rung sits, as a fraction of the top set. Just under it: a rung at the
    # working weight is a working set, and one at 95% is close enough to cost a rep off the
    # first real one.
    TOP_RUNG = 0.875

    # Below this, reps stay at five; at or above it they drop to three. The lifter's own
    # sessions are the evidence for the top end -- on 2026-09-10 the planned 112x3 was done
    # for 5 and the 132x2 for 4 -- so the old 5/5/3/2 taper was more conservative than a
    # trained lifter needs at 60-70%.
    HEAVY = 0.80
    LIGHT_REPS = 5
    HEAVY_REPS = 3

    # How many rungs a ramp may have, the bar included. Two is a floor rather than a
    # calculation: anything above the bar deserves one stop between, however close it is.
    RUNGS = (2..6)

    module_function

    # Returns [{weight:, reps:}, ...] always opening with the empty bar and ending below
    # top_weight. Empty only for work that is not on a barbell: bodyweight, banded and machine
    # lifts ramp differently, if at all -- and for a lift that has asked for no ramp.
    #
    # `loading` is how a percentage of the top weight becomes a number to put on the bar. Given
    # a rack's own -- Equipment#loading -- every rung lands on a weight that rack can build;
    # given nothing it rounds to a multiple of the increment, which is what this did
    # unconditionally and is what wrote the unloadable 124 in #140.
    #
    # `rungs` is the lift's own answer where it has one, and nil where it has not. Zero is a
    # real answer and means no ramp, which is why this tests for nil rather than truthiness --
    # zero is truthy in Ruby, and #321 is what happens when that is forgotten.
    def ramp(top_weight, is_barbell: true, bar_weight: BAR_WEIGHT,
             loading: Rounding::Loading.by_increment, rungs: nil)
      return [] unless is_barbell
      return [] if rungs&.zero?

      # Every barbell lift starts with the bar, including one that works at the bar, where
      # there is nothing above it left to ramp through.
      bar = [{ weight: bar_weight, reps: BAR_REPS }]
      return bar if top_weight.nil? || top_weight <= bar_weight

      climb(bar, top_weight, bar_weight, loading, rungs || fitted(top_weight, bar_weight))
    end

    # How many rungs this top weight wants, from how far it is above the bar.
    #
    # The ratio rounded is the whole rule, and it lands where #451 says it should: 150 on a 45
    # is 3.3 and gets three, 235 is 5.2 and gets five. That is a convention that happens to
    # read well rather than a result -- see the note on the constants above.
    def fitted(top_weight, bar_weight)
      return RUNGS.min unless bar_weight.positive?

      (top_weight / bar_weight.to_f).round.clamp(RUNGS.min, RUNGS.max)
    end

    # The rungs themselves, evenly spaced in fractions of the top weight from where the bar
    # already sits up to TOP_RUNG.
    #
    # Spaced in fractions rather than in pounds because the bar is a different fraction of a
    # 150 than of a 400 -- 30% against 11% -- and even pound steps would put the first rung of
    # a heavy lift at a percentage nobody warms up through.
    def climb(bar, top_weight, bar_weight, loading, rungs)
      fractions(bar_weight / top_weight.to_f, rungs).each_with_object(bar) do |fraction, sets|
        landed = [loading.call(top_weight * fraction), bar_weight].max
        # Rounding can flatten two rungs onto the same weight on a light lift, and lifting the
        # same bar twice is not a ramp -- so a repeat is dropped rather than drawn.
        next unless landed > sets.last[:weight]

        sets << { weight: landed, reps: reps_for(landed / top_weight.to_f) }
      end
    end

    # Where each rung sits as a fraction of the top weight: evenly from where the bar already
    # is up to TOP_RUNG, the bar's own place excluded because it is already on the list.
    def fractions(opening, rungs)
      step = (TOP_RUNG - opening) / (rungs - 1)
      (1...rungs).map { |rung| opening + (step * rung) }
    end

    # Five until the bar is heavy, then three. Off the weight actually landed on rather than
    # the fraction asked for, so a rung rounded across the line counts as the heavier set it
    # has become.
    def reps_for(fraction)
      fraction >= HEAVY ? HEAVY_REPS : LIGHT_REPS
    end
  end
end

