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
    # `shape` carries preferred_reps and is_ascending, which describe how the sets are
    # laid out rather than what they weigh; they travel together because they are the
    # programme's business, while sets/reps/top_weight/increment are the lift's.
    def working_sets(sets:, reps:, top_weight:, increment: Rounding::INCREMENT, **shape)
      target = target_reps(reps, shape[:preferred_reps])
      top = convert_weight(top_weight, from_reps: reps, to_reps: target, increment:)
      return Array.new(sets) { { weight: top, reps: target } } unless shape.fetch(:is_ascending, true)

      ladder(top, sets, increment).map { |weight| { weight:, reps: target } }
    end

    # The loads of an ascending ramp, lightest first.
    #
    # The step is a percentage of the top weight, and a percentage stops being expressible
    # once it rounds to less than the smallest jump the rack can make. At 105 lb a 3% step
    # is 3.15 lb, so on a rack whose lightest pair is 2.5s every set but the last rounds to
    # the same 100 and a 3x8 comes out as 100, 100, 105. Two identical sets labelled as a
    # ramp are worse than a flat prescription: they read as a mistake and invite the lifter
    # to second-guess the sheet.
    #
    # So the percentage is kept wherever it survives rounding, which is every weight heavy
    # enough for 3% to clear a plate change, and below that the ramp falls back to one
    # increment a set -- the smallest ascent that rack can express. A rack with lighter
    # plates therefore ascends where a coarser one cannot, which is the same rule the rest
    # of the app already follows. Where even one increment a set cannot fit above zero the
    # lift is too light to ascend at all and sits flat.
    def ladder(top, sets, increment)
      stepped = stepped_by_percent(top, sets, increment)
      return stepped if stepped.uniq.length == stepped.length

      spaced = stepped_by_increment(top, sets, increment)
      spaced.first.positive? ? spaced : Array.new(sets) { top }
    end

    def stepped_by_percent(top, sets, increment)
      Array.new(sets) { |i| Rounding.to_increment(top * (1 - (ASCENDING_STEP * (sets - 1 - i))), increment:) }
    end

    def stepped_by_increment(top, sets, increment)
      Array.new(sets) { |i| top - ((sets - 1 - i) * increment) }
    end

    # The same intensity expressed at a different rep count: fewer reps means more
    # weight for the same effort. 4×5 @ 155 becomes 4×3 @ 165.
    def convert_weight(top_weight, from_reps:, to_reps:, increment: Rounding::INCREMENT)
      from = RPE8_PERCENTS[from_reps]
      to = RPE8_PERCENTS[to_reps]
      return Rounding.to_increment(top_weight, increment:) unless from && to && from_reps != to_reps

      Rounding.to_increment(top_weight * (to / from), increment:)
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

