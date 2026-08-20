# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Adds an exercise to the account, or returns the one it already has by that
      # name (its own or a shared library movement) rather than duplicating it.
      class CreateExercise < Tool
        tool_name 'create_exercise'
        description 'Add an exercise for the account, deduplicating by name against the ' \
                    "account's own movements and the shared library. Set is_barbell for a " \
                    'movement loaded on a bar, which is what gives its sets plate math; a ' \
                    'name the library already knows is treated as one without being told.'
        scope :write
        input_schema(
          type: 'object',
          properties: { name: { type: 'string' }, icon_url: { type: 'string' },
                        is_barbell: { type: 'boolean' } },
          required: ['name'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = Resolver.exercise(context, name: arguments[:name], icon_url: arguments[:icon_url],
                                                is_barbell: arguments[:is_barbell])
          ok("Exercise '#{exercise.name}' is ready (id #{exercise.id}).",
             structured: Presenter.view_exercise(exercise))
        end
      end
    end
  end
end

