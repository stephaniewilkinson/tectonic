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
                    'name the library already knows is treated as one without being told. ' \
                    'note is coaching intent for the movement -- why it is in the ' \
                    'program, what to watch for, a cue like "this helps correct valgus" ' \
                    "-- and the lifter reads it on the movement's page, so write it to " \
                    'them. Use update_exercise to change a note later.'
        scope :write
        input_schema(
          type: 'object',
          properties: { name: { type: 'string' }, icon_url: { type: 'string' },
                        is_barbell: { type: 'boolean' }, note: { type: 'string' } },
          required: ['name'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = Resolver.exercise(context, name: arguments[:name], icon_url: arguments[:icon_url],
                                                is_barbell: arguments[:is_barbell])
          write_note(exercise, context, arguments) if arguments.key?(:note)
          ok("Exercise '#{exercise.name}' is ready (id #{exercise.id}).",
             structured: Presenter.view_exercise(exercise).merge(note: exercise.note))
        end

        # A note goes on only when the row is this account's. The resolver deduplicates
        # against the shared library as well as the account's own movements, so asking
        # for "Back Squat" with a note hands back the row every account sees, and writing
        # to it would put one lifter's cue on everybody else's page. Refusing beats
        # reporting a success that stored nothing, and nothing is left half done by it:
        # on this path the resolver found an existing row rather than creating one.
        def self.write_note(exercise, context, arguments)
          raise Tool::Refusal, shared(exercise) unless exercise.account_id == context.account_id

          exercise.update(note: Exercise.clean_note(arguments[:note]))
        end

        def self.shared(exercise)
          "'#{exercise.name}' is a movement from the shared library, so it belongs to no account and its " \
            'note is not this one\'s to write. Create a movement of your own under a name of its own and ' \
            'note that instead.'
        end
      end
    end
  end
end

