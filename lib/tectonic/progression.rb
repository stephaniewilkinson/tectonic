# frozen_string_literal: true

require 'roda'
require_relative 'rounding'

class Tectonic < Roda
  # What the next prescription of a lift should be, read off the sessions before it. Three
  # rules decide it and they are deliberately dull, because a lifter has to be able to
  # predict Monday's load on Sunday night, and a rule nobody can anticipate is one nobody
  # trusts enough to follow.
  #
  #   hit every rep     ->  up one increment
  #   fell short once   ->  the same again
  #   fell short twice  ->  down one increment
  #
  # Holding before dropping is the part worth explaining. One failed session is not
  # evidence of a stall: sleep, food and stress move day-to-day performance by more than a
  # rep, so a weight missed on Monday is often one that would have gone up on any other
  # Monday. Repeating it asks the question again under different conditions, and only a
  # second failure answers it. This is the pattern Starting Strength and its descendants
  # settled on, for that reason. A success clears the count, so two failures a month apart
  # with a good week between them are two first failures rather than a stall.
  #
  # A session nobody trained is neither, and is the case a rule most easily gets wrong. It
  # moves the load nowhere and it neither earns a strike nor clears one: absence of proof
  # is not proof of weakness, and dropping the load for a week the lifter was travelling
  # would compound over three such weeks into a prescription far under what they can lift,
  # all of it inferred from days when no bar was touched.
  #
  # The step is one increment rather than a number of pounds, and the increment is passed
  # in. Every rack here makes 5 lb jumps today, because 2.5s on each side is the smallest
  # pair of plates in the inventory; an account with 1 lb plates makes 2 lb jumps, and the
  # same rule then reads "up one increment" without a word of this changing.
  module Progression
    # What a deload week takes off the load it would otherwise have been given.
    DELOAD_FACTOR = 0.9
    # How many failed attempts in a row it takes to call a weight a stall rather than a
    # bad day.
    STRIKES = 2

    module_function

    # The top weight for the next session of a lift: the load the last one prescribed, and
    # the outcomes of the sessions before it, most recent first.
    def next_top_weight(top_weight, outcomes, increment: Rounding::INCREMENT)
      case outcomes.first
      when :met then top_weight + increment
      when :short then stalled?(outcomes) ? backed_off(top_weight, increment) : top_weight
      else top_weight
      end
    end

    # What one session did with what it was asked for. Warmups are not passed in: they are
    # a ramp to the top set and say nothing about whether the top set was there.
    def outcome(sets)
      return :missed unless sets.any? { |set| set[:is_completed] }
      return :met if sets.all? { |set| met?(set) }

      :short
    end

    # Two failed attempts running, counting only the sessions that were actually trained.
    # A week nobody trained sits between them without breaking the run, because it is not
    # a week the lifter answered the question in either direction.
    def stalled?(outcomes)
      attempted = outcomes.reject { |outcome| outcome == :missed }
      attempted.take(STRIKES) == Array.new(STRIKES, :short)
    end

    # A floor at one increment, so a long run of bad weeks lands on the lightest loadable
    # weight rather than at zero or below it. Reaching it means the rule has been wrong for
    # months and a person should be looking at the block, which a load of nothing at least
    # makes obvious.
    def backed_off(top_weight, increment)
      [top_weight - increment, increment].max
    end

    # A deload's reduction, applied to whatever load the rules above arrived at. Load only:
    # cutting the sets as well is the other half of the usual deload, but it would have to
    # reach inside SetScheme, and a week at ninety percent is already a week that recovers.
    def deloaded(top_weight, increment: Rounding::INCREMENT)
      Rounding.to_increment(top_weight * DELOAD_FACTOR, increment:)
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

