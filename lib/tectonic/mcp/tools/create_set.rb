# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
# Exercise#barbell?, which is what a logged set inherits its plate math from.
require_relative '../../exercise_library'

class Tectonic < Roda
  module MCP
    module Tools
      # Logs one set: resolves-or-creates the exercise by name and the workout by
      # date (both through the shared Resolver, so the set can only ever land on the
      # account's own workout), after range-checking weight and reps.
      class CreateSet < Tool
        WEIGHT = (0..2000)
        REPS = (1..100)

        tool_name 'create_set'
        description 'Log a set of an exercise (by name) into a workout (by date, ' \
                    "'today' by default). Weights are integer pounds."
        scope :write
        input_schema(
          type: 'object',
          properties: {
            exercise: { type: 'string' }, date: { type: 'string' },
            weight: { type: 'integer' }, reps: { type: 'integer' },
            is_warmup: { type: 'boolean' }, is_completed: { type: 'boolean' }
          },
          required: %w[exercise weight reps], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          check_range(arguments)
          exercise = Resolver.exercise(context, name: arguments[:exercise])
          workout = Resolver.workout(context, date: arguments[:date])
          set = Set.create(attributes(arguments, exercise, workout, context))
          ok("Logged #{set.weight}x#{set.reps} of #{exercise.name} (id #{set.id}).",
             structured: Presenter.view_set(set))
        end

        # Range lives here, not in the schema, so an out-of-range value refuses with a
        # message that names the bound rather than a generic validation error.
        def self.check_range(arguments)
          unless WEIGHT.cover?(arguments[:weight])
            raise Tool::Refusal, "Weight #{arguments[:weight]} is out of range; use #{WEIGHT.first}-#{WEIGHT.last} lb."
          end
          return if REPS.cover?(arguments[:reps])

          raise Tool::Refusal, "Reps #{arguments[:reps]} is out of range; use #{REPS.first}-#{REPS.last}."
        end

        # is_barbell comes off the movement rather than the arguments: whether a lift is
        # loaded on a bar is a fact about the lift, not something a model should be asked
        # to assert, and a schema that asked would get it wrong or omitted and the set
        # would lose its plate math either way.
        def self.attributes(arguments, exercise, workout, context)
          { exercise_id: exercise.id, workout_id: workout.id,
            weight: arguments[:weight], reps: arguments[:reps],
            is_warmup: arguments.fetch(:is_warmup, false),
            is_completed: arguments.fetch(:is_completed, false), is_barbell: exercise.barbell?,
            created_by_oauth_application_id: context.application_id, created_at: Time.now }
        end
      end
    end
  end
end

