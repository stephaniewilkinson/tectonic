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
        tool_name 'create_set'
        description 'Log a set of an exercise (by name) into a workout (by date, ' \
                    "'today' by default). Weights are integer pounds, rpe is how hard " \
                    'that set was on the 1-10 scale.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            exercise: { type: 'string' }, date: { type: 'string' },
            weight: { type: 'number' }, reps: { type: 'integer' }, rpe: { type: 'integer' },
            is_warmup: { type: 'boolean' }, is_completed: { type: 'boolean' }
          },
          required: %w[exercise weight reps], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          check_range(arguments)
          exercise = Resolver.exercise(context, name: arguments[:exercise])
          workout = Resolver.workout(context, date: arguments[:date])
          set = WorkoutSet.create(attributes(arguments, exercise, workout, context))
          ok("Logged #{Presenter.load_phrase(set)} of #{exercise.name} (id #{set.id}).",
             structured: Presenter.view_set(set))
        end

        # The ranges are Bounds', shared with every other tool that writes a weight or a
        # rep count, so the same number is refused the same way whether it is being
        # logged here, revised through update_set, or prescribed in a program.
        def self.check_range(arguments)
          Bounds.check(Bounds::WEIGHT, arguments[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, arguments[:reps], 'Reps')
          Bounds.check(Bounds::RPE, arguments[:rpe], 'RPE')
          # This tool takes no measure, so every set it writes is counted in reps and only
          # is_warmup can put a rating somewhere it does not belong.
          Bounds.rating_fits!(arguments[:rpe], warmup: arguments.fetch(:is_warmup, false), timed: false)
        end

        # is_barbell comes off the movement rather than the arguments: whether a lift is
        # loaded on a bar is a fact about the lift, not something a model should be asked
        # to assert, and a schema that asked would get it wrong or omitted and the set
        # would lose its plate math either way.
        def self.attributes(arguments, exercise, workout, context)
          { exercise_id: exercise.id, workout_id: workout.id,
            weight: arguments[:weight], reps: arguments[:reps], rpe: arguments[:rpe],
            is_warmup: arguments.fetch(:is_warmup, false), is_barbell: exercise.barbell?,
            # A set logged as already done is stamped with when it was logged, which is the
            # best this path can say (#281). It is not when it was lifted -- a session typed
            # up in the evening stamps the evening -- so the turnarounds such a session
            # produces describe the typing rather than the training. That is honest about
            # what the column holds and is why Timing never claims a turnaround is a rest.
            **WorkoutSet.completion(arguments.fetch(:is_completed, false)),
            created_by_oauth_application_id: context.application_id, created_at: Time.now }
        end
      end
    end
  end
end

