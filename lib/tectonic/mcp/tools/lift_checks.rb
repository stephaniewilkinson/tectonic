# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../measured'

class Tectonic < Roda
  module MCP
    module Tools
      # Whether a lift's prescription can be written at all: each number within its bounds,
      # and the numbers sensible together. #605.
      #
      # Its own module and still one place. ProgramWriter is the one path every program write
      # takes, so that a lift added to a day and a lift written in a whole new block are
      # checked by the same rules, and that is unchanged -- it calls these, and so does the
      # tool that edits a lift, which is the second caller they always had. What moved is the
      # rules themselves, out of the module that builds the rows, which is what let it fit.
      module LiftChecks
        module_function

        # Two kinds of check, split because they answer different questions. check_numbers
        # asks whether each figure is within its own bounds; everything below it asks whether
        # the figures make sense *together* -- a measure with the quantity it needs, a target
        # where a target can sit, a reference with something to reference, a price stated
        # exactly one way.
        def check_load(attributes, shape)
          check_numbers(attributes, shape)
          check_measure(shape, attributes[:measure])
          # How large a target may be and where it may sit are one question, asked in Bounds
          # beside where a *rating* may sit -- the same rule about the same scale, put to the
          # prescription and to the answer. Refused by name here rather than left to
          # program_lifts_target_rpe_on_working_reps, which enforces it again: a constraint
          # violation reaches a client as a database error and reads as the tool being
          # broken, and the constraint stays as the backstop for anything that never comes
          # through this writer.
          Bounds.target_fits!(attributes[:target_rpe], measure: shape[:measure], weighted: shape[:is_weighted])
          Bounds.commands_fit!(attributes[:is_commanded], measure: shape[:measure])
          Bounds.setup_fits!(attributes)
          Bounds.reference_fits!(attributes[:percent_of], percent: attributes[:percent_of_max])
          check_priced(attributes, shape)
        end

        def check_numbers(attributes, shape)
          Bounds.check(Bounds::SETS, attributes[:sets], 'Sets')
          Bounds.check(Bounds::REPS, shape[:reps], 'Reps')
          Bounds.check(Bounds::SECONDS, shape[:duration_seconds], 'Duration', unit: ' seconds')
          Bounds.check(Bounds::WEIGHT, attributes[:top_weight], 'Top weight', unit: ' lb')
          Bounds.check(Bounds::PERCENT, attributes[:percent_of_max], 'Percent of max', unit: '%')
          Bounds.check(Bounds::REST, attributes[:rest_seconds], 'Rest', unit: ' seconds')
          Bounds.check(Bounds::WARMUP_SETS, attributes[:warmup_sets], 'Warmup sets')
        end

        # A lift is counted one way or the other, and the way it is counted decides which
        # quantity it needs. Asking for time without saying how long is a prescription
        # nobody can follow.
        def check_measure(shape, given)
          raise Tool::Refusal, "Measure #{given.inspect} is not one of reps or time." unless shape[:measure]

          timed = shape[:measure] == Measured::TIME
          return if timed ? shape[:duration_seconds] : shape[:reps]

          raise Tool::Refusal, timed ? 'A timed lift needs duration_seconds.' : 'A lift counted in reps needs reps.'
        end

        # A written zero was the old workaround for bodyweight work, and it is not
        # harmless: zero reads as a real starting load, gains an increment every week the
        # lifter completes it, and three weeks later the app is prescribing a weighted
        # plank.
        def check_priced(attributes, shape)
          return check_unweighted(attributes) unless shape[:is_weighted]
          raise Tool::Refusal, zero_message if attributes[:top_weight]&.zero?
          return if attributes[:top_weight].nil? ^ attributes[:percent_of_max].nil?

          raise Tool::Refusal, 'A lift needs exactly one of top_weight (pounds) or ' \
                               'percent_of_max (a percentage of the estimated max for that movement), ' \
                               'unless is_weighted is false.'
        end

        # Unweighted work carries no load of either kind. Saying it is unweighted and then
        # pricing it is two answers to one question, and the row would fail the database's
        # own check anyway, so it is refused here where the message can name the field.
        def check_unweighted(attributes)
          return if attributes[:top_weight].nil? && attributes[:percent_of_max].nil?

          raise Tool::Refusal, 'An unweighted lift carries no load, so it cannot also have a ' \
                               'top_weight or a percent_of_max. Drop the load, or set is_weighted.'
        end

        def zero_message
          'A lift cannot weigh zero. For a plank, a band, or anything carrying no external ' \
            'load, set is_weighted to false instead.'
        end
      end
    end
  end
end

