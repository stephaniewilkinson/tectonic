# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../rack_change'

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
                    'icon_url, whether it is loaded on a bar, whether its reps are counted ' \
                    'per side, how many dumbbells it takes, and how long it is rested. ' \
                    'note is coaching intent for the movement -- why it is in the program, ' \
                    'what to watch for, a cue like "this helps correct valgus" -- and the ' \
                    "lifter reads it on the movement's page, so write it to them. " \
                    'dumbbell_count is 1 or 2 and decides which weights exist for the ' \
                    'movement at all, since every plate size has to go on both ends of ' \
                    'every handle in use; null means nobody has said, and the app then ' \
                    'assumes two. Send only what changes; send note as null or an empty ' \
                    'string to clear it. Movements from the shared library belong to no ' \
                    'account and cannot be edited here. Returns what actually moved, and ' \
                    'says so when a change rewrote logged sets or upcoming sessions.'
        scope :write
        input_schema(
          type: 'object',
          properties: { exercise_id: { type: 'integer' }, name: { type: 'string' },
                        note: TEXT_OR_NULL, icon_url: TEXT_OR_NULL,
                        is_barbell: { type: 'boolean' },
                        default_is_per_side: { type: 'boolean' },
                        dumbbell_count: { type: %w[integer null], enum: [1, 2, nil] },
                        default_rest_seconds: { type: %w[integer null] } },
          required: ['exercise_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = own(context, arguments[:exercise_id])
          was = { per_side: exercise.default_is_per_side, dumbbells: exercise.dumbbells }
          changed = Changes.apply(exercise, fields(arguments))
          reached = reached(context, exercise.refresh, was)
          ok("#{exercise.name}: #{Changes.describe(changed)}.#{reach_sentence(reached)}",
             structured: Presenter.view_exercise(exercise).merge(note: exercise.note, changed:, **reached))
        end

        # What an edit here reaches beyond the row it edits, which is what makes two of these
        # fields different in kind from a rename. #454.
        #
        # The browser form has always done both, and reported both, and the tool could set
        # neither field -- so the comment above claiming the two ways in "change the same
        # things and no more" had quietly stopped being true. These are the fields it was
        # missing, and the consequences come with them rather than after them: a tool that set
        # the column and skipped the rewrite would leave the sessions saying one thing and the
        # movement another, which is exactly the staleness #465 fixed on the rack side.
        #
        # Reported in the sentence as well as the payload, because both rewrite data the
        # lifter already has. An assistant that changes a count and is told only "changed" has
        # no way to mention that eleven logged sets now count twice the reps.
        def self.reached(context, exercise, was)
          { sets_recounted: recount(context, exercise, was),
            sessions_rerounded: reround(context, exercise, was) }
        end

        # Saying a movement is counted per side is a statement about the movement rather than
        # about today, so the sets that were following the old answer follow the new one. #392.
        def self.recount(context, exercise, was)
          return 0 if exercise.default_is_per_side == was[:per_side]

          Exercise.align_sets_per_side(exercise, context.account_id, was: was[:per_side])
        end

        # And saying how many dumbbells changes which weights exist for the movement, so the
        # sessions already written against the old answer are brought onto the new one. #439.
        #
        # Compared on `dumbbells` rather than on the column, so filling a blank in as two --
        # which is what the app was already assuming -- correctly counts as no change and
        # rewrites nothing.
        def self.reround(context, exercise, was)
          return 0 if exercise.dumbbells == was[:dumbbells]

          RackChange.reround(context.account_id, today: context.today)
        end

        REACHED = { sets_recounted: 'logged set(s) recounted',
                    sessions_rerounded: 'upcoming session(s) rewritten onto weights it can load' }.freeze

        # Only what actually moved. A rename reporting "0 sessions rewritten" would read as
        # though it had considered rewriting some.
        def self.reach_sentence(reached)
          said = REACHED.filter_map { |field, phrase| "#{reached[field]} #{phrase}" if reached[field].positive? }
          said.empty? ? '' : " #{said.join(', ')}."
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
        #
        # The two numeric fields go through the same cleaners the form posts into, rather than
        # straight at the column. Both have check constraints behind them, and a value that
        # fails one surfaces as a tool crashing rather than as an answer -- `clean_rest_seconds`
        # turning 9000 into null is the deliberate refusal described there, not a clamp.
        # Taken as sent. Three flags and a url the column can hold as they arrive.
        AS_SENT = %i[icon_url is_barbell default_is_per_side].freeze

        # And the four that go through a cleaner, which is the same cleaner the browser form
        # posts into -- so a value set by a person and one set by an assistant are cleaned by
        # one rule rather than by two that can drift.
        CLEANED = { name: ->(raw) { clean_name(raw) },
                    note: ->(raw) { Exercise.clean_note(raw) },
                    dumbbell_count: ->(raw) { Exercise.clean_dumbbell_count(raw) },
                    default_rest_seconds: ->(raw) { Exercise.clean_rest_seconds(raw) } }.freeze

        def self.fields(arguments)
          cleaned = CLEANED.filter_map do |field, clean|
            [field, clean.call(arguments[field])] if arguments.key?(field)
          end
          arguments.slice(*AS_SENT).merge(cleaned.to_h)
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

