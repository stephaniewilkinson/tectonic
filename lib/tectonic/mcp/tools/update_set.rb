# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Corrects a set that is already there: its weight, its reps, its rating, whether it
      # is a warmup, or which movement it is. Distinct from complete_set, which is about
      # having lifted something; this is about the row being wrong.
      class UpdateSet < Tool
        tool_name 'update_set'
        description 'Correct a set: weight, reps, rpe, whether it is a warmup, or the ' \
                    'exercise it is. Send only what changes. Returns what actually moved.'
        scope :write
        input_schema(
          type: 'object',
          properties: { set_id: { type: 'integer' }, weight: { type: 'number' },
                        reps: { type: 'integer' }, rpe: { type: 'integer' },
                        is_warmup: { type: 'boolean' }, exercise: { type: 'string' } },
          required: ['set_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          set = Resolver.find_set(context, arguments[:set_id])
          changed = Changes.apply(set, attributes(context, set, arguments))
          ok("#{set.exercise.name} #{set.weight}x#{set.reps}: #{Changes.describe(changed)}.",
             structured: Presenter.view_set(set.refresh).merge(changed:))
        end

        # A set moved onto another movement takes that movement's barbell flag with it,
        # the same rule the edit form in the web UI follows: plate math describing the
        # lift that was swapped out is worse than no plate math at all.
        def self.attributes(context, set, arguments)
          fields = arguments.slice(:weight, :reps, :rpe, :is_warmup)
          check(fields)
          return fields unless arguments[:exercise]

          exercise = Resolver.exercise(context, name: arguments[:exercise])
          return fields if exercise.id == set.exercise_id

          { exercise_id: exercise.id, is_barbell: exercise.barbell? }.merge(fields)
        end

        def self.check(fields)
          Bounds.check(Bounds::WEIGHT, fields[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, fields[:reps], 'Reps')
          Bounds.check(Bounds::RPE, fields[:rpe], 'RPE')
        end
      end
    end
  end
end

