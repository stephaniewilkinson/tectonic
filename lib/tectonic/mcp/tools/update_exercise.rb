# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Edits a movement the account owns: what it is called, whether it is loaded on a
      # bar, and the note the lifter reads on its page. The note is why this tool exists
      # -- an assistant that can write a block should be able to write down why a
      # movement is in it, and revise that when the block changes -- but a note and a
      # rename are the same act on the same row, so this is one tool with one more field
      # rather than a note-only tool sitting beside create_exercise. The fields are
      # exactly the ones the exercise form offers a person, which is the point: the two
      # ways in change the same things and no more.
      class UpdateExercise < Tool
        # Sending null is how a caller clears a note or an icon, which a plain 'string'
        # schema has no way to express. Anything the model does not send is left alone.
        TEXT_OR_NULL = { type: %w[string null] }.freeze

        tool_name 'update_exercise'

        title 'Edit a movement'
        description 'Change a movement this account owns: its name, its note, its ' \
                    'icon_url, or whether it is loaded on a bar. note is coaching intent ' \
                    'for the movement -- why it is in the program, what to watch for, ' \
                    'a cue like "this helps correct valgus" -- and the lifter reads it on ' \
                    "the movement's page, so write it to them. Send only what changes; " \
                    'send note as null or an empty string to clear it. Movements from the ' \
                    'shared library belong to no account and cannot be edited here. ' \
                    'Returns what actually moved.'
        scope :write
        input_schema(
          type: 'object',
          properties: { exercise_id: { type: 'integer' }, name: { type: 'string' },
                        note: TEXT_OR_NULL, icon_url: TEXT_OR_NULL,
                        is_barbell: { type: 'boolean' } },
          required: ['exercise_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = own(context, arguments[:exercise_id])
          changed = Changes.apply(exercise, fields(arguments))
          ok("#{exercise.name}: #{Changes.describe(changed)}.",
             structured: Presenter.view_exercise(exercise.refresh).merge(note: exercise.note, changed:))
        end

        # The row, scoped to what the account owns rather than to what it can see. The
        # two differ by exactly the shared library, and that difference is the whole
        # ownership question: a library movement is on every account's page, so an edit
        # to one is an edit to what every other account reads.
        def self.own(context, id)
          Exercise.owned_by(context.account_id).where(id:).first || (raise Tool::Refusal, why(context, id))
        end

        # Refusing rather than returning nil, because a model handed a silent nil reports
        # a successful edit that touched nothing. Which kind of no it was is worth saying:
        # an assistant told "no such exercise" about a library movement it can plainly see
        # in list_exercises will conclude the id was wrong and try the same thing again.
        def self.why(context, id)
          shared = context.exercises.where(id:).first
          return "No exercise with id #{id.inspect} on this account." unless shared&.library?

          "'#{shared.name}' comes from the shared library, so it belongs to no account and cannot be " \
            'edited. Create a movement of your own under a name of its own and edit that instead.'
        end

        # The columns an edit may set, and only the ones the caller actually sent. A
        # missing key means "leave it" where a key holding null means "clear it", and the
        # two have to stay apart or renaming a movement would silently wipe its note.
        def self.fields(arguments)
          attributes = arguments.slice(:icon_url, :is_barbell)
          attributes[:name] = clean_name(arguments[:name]) if arguments.key?(:name)
          attributes[:note] = Exercise.clean_note(arguments[:note]) if arguments.key?(:note)
          attributes
        end

        # The same floor Resolver puts under a created movement. The column is NOT NULL
        # but an empty string satisfies that, and a movement with no name is unfindable
        # in every list that sorts by one.
        def self.clean_name(raw)
          clean = raw.to_s.strip
          raise Tool::Refusal, 'An exercise needs a non-empty name.' if clean.empty?

          clean
        end
      end
    end
  end
end

