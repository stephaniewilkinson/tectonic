# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # Working sets: how many, at what load, for how many reps. Both behaviours here
  # are preferences rather than laws, so a program carries its own settings for
  # them and this module only applies what it is handed.
  module SetScheme
    # Percentage of 1RM a set at this rep count represents when taken at RPE 8, from the
    # standard RPE chart.
    #
    # **One row is the whole chart.** The RTS chart is constructed as a single shifted
    # sequence: RPE 8 at three reps, RPE 9 at four and RPE 10 at five are all the same number.
    # So storing this row and shifting by `reps + 8 - rating` -- which is what OneRepMax does
    # to read a set at any rating -- is exactly equivalent to storing the full grid, and
    # nothing is lost by keeping one line instead of thirty.
    #
    # It ran to five reps and now runs to ten. That extension is only for the *estimate*: see
    # CONVERTIBLE below, which is what keeps it from changing a single prescription.
    RPE8_PERCENTS = {
      10 => 68.0, 9 => 70.7, 8 => 73.9, 7 => 76.2, 6 => 78.6,
      5 => 81.1, 4 => 83.8, 3 => 86.3, 2 => 88.7, 1 => 92.4
    }.freeze
    # The rep counts a *prescription* may be converted between, as against the ones an
    # estimate may be read from. Deliberately narrower than the table above, and this is the
    # whole of why extending that table changes no generated weight.
    #
    # `target_reps` used to refuse a conversion by asking whether the chart covered the rep
    # count, so a lift written at eight reps was exempt from rep conversion because eight
    # happened to be off the end. Extending the chart would have quietly removed that
    # exemption and started rewriting every high-rep accessory in a block with a preferred
    # rep count -- which is a change to somebody's programme, arrived at as a side effect of
    # fixing an estimate.
    #
    # So the exemption is now a rule rather than an accident of where the table stopped. It
    # is also the only thing enforcing that rep schemes vary by lift rather than being driven
    # globally from one setting, which is a decision worth having in one named place.
    CONVERTIBLE = (1..5)
    # How far below the top weight each earlier set sits, per set.
    ASCENDING_STEP = 0.03

    module_function

    # Returns [{weight:, reps:}, ...] in the order they should be lifted, climbing
    # to top_weight rather than sitting flat unless is_ascending is false.
    # `shape` carries preferred_reps and is_ascending, which describe how the sets are
    # laid out rather than what they weigh; they travel together because they are the
    # programme's business, while sets/reps/top_weight/increment are the lift's.
    # `loading` turns a calculated load into a number to put on the bar, and says how far
    # apart two rungs sit. Given a rack's own -- Equipment#loading -- every weight here
    # lands on something that rack can build; given nothing it rounds to a multiple of the
    # increment, which is what it always did and what #140 is about.
    def working_sets(sets:, reps:, top_weight:, loading: Rounding::Loading.by_increment, **shape)
      target = target_reps(reps, shape[:preferred_reps])
      top = convert_weight(top_weight, from_reps: reps, to_reps: target, loading:)
      return Array.new(sets) { { weight: top, reps: target } } unless shape.fetch(:is_ascending, true)

      ladder(top, sets, loading).map { |weight| { weight:, reps: target } }
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
    # The increment-spaced fallback is rounded now too, so that every rung is a weight the
    # rack can build rather than only the ones the percentage produced. That can collapse
    # two rungs onto one weight where the exact arithmetic did not -- a rack whose small
    # plates run out has gaps in it, and one increment of nominal space can fall inside a
    # gap -- so it is checked for repeats on the same terms as the percentage ladder, and
    # falls flat when it has them. Two identical sets labelled as a ramp were the thing
    # this method was written to avoid.
    def ladder(top, sets, loading)
      stepped = stepped_by_percent(top, sets, loading)
      return stepped if stepped.uniq.length == stepped.length

      spaced = stepped_by_increment(top, sets, loading)
      return spaced if spaced.first.positive? && spaced.uniq.length == spaced.length

      Array.new(sets) { top }
    end

    def stepped_by_percent(top, sets, loading)
      Array.new(sets) { |i| loading.call(top * (1 - (ASCENDING_STEP * (sets - 1 - i)))) }
    end

    def stepped_by_increment(top, sets, loading)
      Array.new(sets) { |i| loading.call(top - ((sets - 1 - i) * loading.increment)) }
    end

    # The same intensity expressed at a different rep count: fewer reps means more
    # weight for the same effort. 4×5 @ 155 becomes 4×3 @ 165.
    def convert_weight(top_weight, from_reps:, to_reps:, loading: Rounding::Loading.by_increment)
      return loading.call(top_weight) unless convertible?(from_reps) && convertible?(to_reps)
      return loading.call(top_weight) if from_reps == to_reps

      loading.call(top_weight * (RPE8_PERCENTS[to_reps] / RPE8_PERCENTS[from_reps]))
    end

    # Asked of CONVERTIBLE rather than of the chart, which is the distinction that lets the
    # chart grow without any prescription moving. `nil` is not convertible, which is what the
    # old `from && to` guard was really testing.
    def convertible?(reps)
      !reps.nil? && CONVERTIBLE.cover?(reps)
    end

    # Converts down to the preferred rep count, never up, and only between rep counts
    # CONVERTIBLE covers -- a prescribed set of 8 stays a set of 8.
    #
    # That last clause used to read "only between rep counts the chart actually covers", and
    # the chart stopping at five was the only thing making it true. It now asks the rule
    # directly, so a set of 8 goes on staying a set of 8 while the estimate reads up to ten.
    def target_reps(reps, preferred_reps)
      return reps unless preferred_reps && preferred_reps < reps
      return reps unless convertible?(reps) && convertible?(preferred_reps)

      preferred_reps
    end
  end
end

