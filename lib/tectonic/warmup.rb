# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # Warmup ramps, from the empty bar up to just under the working weight.
  module Warmup
    BAR_WEIGHT = 45
    BAR_REPS = 5

    # Ramp sets above the bar, as a percentage of the top working weight paired
    # with its rep count, chosen by how heavy that top weight is. Reps descend as
    # the weight climbs, and a lighter lift needs less of a ramp to get there.
    TIERS = [
      [136, [[0.60, 5], [0.75, 3], [0.875, 2]].freeze],
      [96, [[0.70, 5], [0.875, 3]].freeze],
      [0, [[0.80, 3]].freeze]
    ].freeze

    module_function

    # Returns [{weight:, reps:}, ...] always opening with the empty bar and ending
    # below top_weight. Empty only for work that is not on a barbell: bodyweight,
    # banded and machine lifts ramp differently, if at all.
    def ramp(top_weight, is_barbell: true, bar_weight: BAR_WEIGHT)
      return [] unless is_barbell

      # Every barbell lift starts with the bar, including one that works at the
      # bar, where there is nothing above it left to ramp through.
      bar = [{ weight: bar_weight, reps: BAR_REPS }]
      return bar if top_weight.nil? || top_weight <= bar_weight

      _, ramps = TIERS.find { |minimum, _| top_weight >= minimum }
      ramps.each_with_object(bar) do |(percent, reps), sets|
        weight = [Rounding.to_increment(top_weight * percent), bar_weight].max
        # Rounding can flatten two ramp steps onto the same weight on a light
        # lift. Lifting the same bar twice is not a ramp, so drop the repeat.
        sets << { weight:, reps: } if weight > sets.last[:weight]
      end
    end
  end
end

