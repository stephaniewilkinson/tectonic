# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # Working sets: how many, at what load, for how many reps. Both behaviours here
  # are preferences rather than laws, so a program carries its own settings for
  # them and this module only applies what it is handed.
  module SetScheme
    # Percentage of 1RM a set at this rep count represents when taken at RPE 8,
    # from the standard RPE chart.
    RPE8_PERCENTS = { 5 => 81.1, 4 => 83.8, 3 => 86.3, 2 => 88.7, 1 => 92.4 }.freeze
    # How far below the top weight each earlier set sits, per set.
    ASCENDING_STEP = 0.03

    module_function

    # Returns [{weight:, reps:}, ...] in the order they should be lifted, climbing
    # to top_weight rather than sitting flat unless is_ascending is false.
    def working_sets(sets:, reps:, top_weight:, preferred_reps: nil, is_ascending: true)
      target = target_reps(reps, preferred_reps)
      top = convert_weight(top_weight, from_reps: reps, to_reps: target)

      Array.new(sets) do |index|
        below_top = is_ascending ? sets - 1 - index : 0
        { weight: Rounding.to_increment(top * (1 - (ASCENDING_STEP * below_top))), reps: target }
      end
    end

    # The same intensity expressed at a different rep count: fewer reps means more
    # weight for the same effort. 4×5 @ 155 becomes 4×3 @ 165.
    def convert_weight(top_weight, from_reps:, to_reps:)
      from = RPE8_PERCENTS[from_reps]
      to = RPE8_PERCENTS[to_reps]
      return Rounding.to_increment(top_weight) unless from && to && from_reps != to_reps

      Rounding.to_increment(top_weight * (to / from))
    end

    # Converts down to the preferred rep count, never up, and only between rep
    # counts the chart actually covers -- a prescribed set of 8 stays a set of 8.
    def target_reps(reps, preferred_reps)
      return reps unless preferred_reps && preferred_reps < reps
      return reps unless RPE8_PERCENTS.key?(reps) && RPE8_PERCENTS.key?(preferred_reps)

      preferred_reps
    end
  end
end