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
        title 'Add a movement'
        description "Add an exercise, deduplicated by name against the account's movements " \
                    'and the shared library; an existing match is returned instead. is_barbell ' \
                    'gives its sets plate math (library names are barbell already). note is shown ' \
                    "to the lifter on the movement's page. If the name could mean an existing " \
                    'movement ("Squat" beside "Back Squat") it refuses and lists them; ' \
                    'new_exercise true adds it anyway.'
        scope :write
        input_schema(
          type: 'object',
          properties: { name: { type: 'string' }, icon_url: { type: 'string' },
                        is_barbell: { type: 'boolean' }, note: { type: 'string' },
                        new_exercise: { type: 'boolean' } },
          required: ['name'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          # The one door that can say yes to a name the account may already have under
          # another one (#478). Every other tool refuses and points here, which is what keeps
          # the decision deliberate and in one place.
          exercise = Resolver.exercise(context, name: arguments[:name], icon_url: arguments[:icon_url],
                                                is_barbell: arguments[:is_barbell],
                                                new_exercise: arguments[:new_exercise])
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

