# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # What the next prescription of a lift should be, read off the last one and what was
  # actually done against it. Three rules decide it and they are deliberately dull, because
  # a lifter has to be able to predict Monday's load on Sunday night, and a rule nobody can
  # anticipate is one nobody trusts enough to follow.
  #
  #   trained it all as written   ->  five pounds more
  #   trained it and fell short   ->  ten pounds less
  #   did not train it at all     ->  the same again
  #
  # The asymmetry between the step up and the step down is the point. Adding is a guess
  # that the lifter is stronger, and a wrong guess costs a session; subtracting is a
  # response to evidence that the load was too heavy, and coming back at the same weight
  # that just failed wastes the week. Twice the step gets clear of it in one go rather than
  # grinding at the edge of failure for a fortnight.
  #
  # A session nobody trained is not evidence of anything, so it moves nothing. Absence of
  # proof is the case a rule most easily gets wrong: dropping the load for a week the
  # lifter was travelling would compound over three such weeks into a prescription far
  # under what they can lift, all of it inferred from days when no bar was touched.
  module Progression
    # Up by the smallest change a bar can actually make, down by two of them.
    ADVANCE = Rounding::INCREMENT
    REGRESS = Rounding::INCREMENT * 2
    # What a deload week takes off the load it would otherwise have been given.
    DELOAD_FACTOR = 0.9

    module_function

    # The top weight for the next session of a lift, given what the last one prescribed and
    # the working sets it was prescribed as. Warmups are not passed in: they are a ramp to
    # the top set and say nothing about whether the top set was there.
    def next_top_weight(top_weight, sets)
      return top_weight unless trained?(sets)
      return top_weight + ADVANCE if sets.all? { |set| met?(set) }

      # A floor, so a long run of bad weeks lands on an empty bar rather than at zero or
      # below it. Reaching it means the rule has been wrong for months and a person should
      # be looking at the block, which a load of nothing at least makes obvious.
      [top_weight - REGRESS, Rounding::INCREMENT].max
    end

    # A deload's reduction, applied to whatever load the rules above arrived at. Load only:
    # cutting the sets as well is the other half of the usual deload, but it would have to
    # reach inside SetScheme, and a week at ninety percent is already a week that recovers.
    def deloaded(top_weight)
      Rounding.to_increment(top_weight * DELOAD_FACTOR)
    end

    # Whether the session happened at all, which is one completed set: the same test the
    # workout list uses to tell a session that was performed from one that was only ever
    # written down.
    def trained?(sets)
      sets.any? { |set| set[:is_completed] }
    end

    # Whether a set answered what was asked of it. Lifting more than the prescription, or
    # for more reps, counts as meeting it -- the lifter had it that day and the rule has no
    # business calling that a shortfall. A set with nothing planned against it was not part
    # of a prescription and cannot fall short of one.
    def met?(set)
      return false unless set[:is_completed]
      return true unless set[:planned_weight] && set[:planned_reps]

      set[:weight] >= set[:planned_weight] && set[:reps] >= set[:planned_reps]
    end
  end
end

