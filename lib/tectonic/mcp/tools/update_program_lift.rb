# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Edits one prescribed lift: its load, its volume, the movement it is, or where it
      # sits in the day. One tool rather than four, because "change the squat to 175",
      # "make it triples", "swap it for a front squat" and "move it after the bench" are
      # the same act on the same row, and a model choosing between four near-identical
      # tools chooses wrong more often than it fills in one more field.
      class UpdateProgramLift < Tool
        NUMBER_OR_NULL = { type: %w[integer null] }.freeze
        # The arguments that change how a lift is done rather than what it weighs. Any one of
        # them re-derives the whole shape, since the measure decides which quantity column
        # carries the number and the other has to be emptied.
        SHAPE_FIELDS = %i[is_weighted is_per_side measure duration_seconds].freeze

        tool_name 'update_program_lift'
        description 'Change a prescribed lift: sets, reps, top_weight or percent_of_max, ' \
                    'the exercise it is, whether it is the main work, or its position in ' \
                    'the day (0 is first). is_weighted, is_per_side, measure and ' \
                    'duration_seconds change how the lift is done -- loading a movement that ' \
                    'was written unweighted, holding one that was counted in reps, or ' \
                    'flagging a count as per side after the fact. target_rpe, 1 to 10, is ' \
                    'the effort its working ' \
                    'sets are meant to be taken at, on a loaded lift counted in reps; send ' \
                    'null to clear it. Send only what changes. To swap how the load is ' \
                    'written, set one of top_weight/percent_of_max and null the other. ' \
                    'Returns what actually moved.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            program_lift_id: { type: 'integer' }, exercise: { type: 'string' },
            sets: { type: 'integer' }, reps: { type: 'integer' },
            top_weight: NUMBER_OR_NULL, percent_of_max: NUMBER_OR_NULL,
            position: { type: 'integer' }, is_main: { type: 'boolean' },
            is_barbell: { type: 'boolean' }, target_rpe: NUMBER_OR_NULL,
            percent_of: { type: %w[string null] }, is_weighted: { type: 'boolean' },
            is_per_side: { type: 'boolean' }, measure: { type: 'string', enum: %w[reps time] },
            duration_seconds: { type: 'integer' }, note: { type: 'string' }
          },
          required: ['program_lift_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          lift = ProgramFinder.lift(context, arguments[:program_lift_id])
          changed = DB.transaction { revise(context, lift, arguments) }
          day = lift.program_day
          refreshed = SessionRefresh.apply(day)
          ok("#{lift.exercise.name}: #{Changes.describe(changed)}.#{SessionRefresh.sentence(refreshed, day)}",
             structured: ProgramView.lift(lift.refresh).merge(changed:, session: refreshed.to_s))
        end

        def self.revise(context, lift, arguments)
          attributes = fields(context, lift, arguments)
          check(lift, attributes)
          changed = Changes.apply(lift, attributes)
          changed.merge(move(lift, arguments[:position]))
        end

        # The columns an edit may set. A substitution takes the new movement's barbell
        # flag with it unless the caller says otherwise, because plate math describing the
        # lift that was swapped out is worse than none -- the same rule the web UI follows.
        def self.fields(context, lift, arguments)
          written = arguments.slice(:sets, :reps, :top_weight, :percent_of_max,
                                    :is_main, :is_barbell, :target_rpe, :note)
          attributes = round_load(context, lift, written, arguments)
                       .merge(reference(context, arguments))
                       .merge(reshaped(lift, arguments))
                       .merge(repriced(lift, arguments))
          return attributes unless arguments[:exercise]

          exercise = Resolver.exercise(context, name: arguments[:exercise])
          return attributes if exercise.id == lift.exercise_id

          { exercise_id: exercise.id, is_barbell: exercise.barbell? }.merge(attributes)
        end

        # The four columns that say how a lift is done, and the quantity that follows from
        # them. #305: create_program and add_program_lift have always accepted these and this
        # tool did not, so a lift's shape was fixed at the moment it was written and the only
        # way to change it was to delete the lift and add it back -- losing its position and
        # its note.
        #
        # The concrete case, and the reason it was sharp: a split squat written unweighted
        # and later loaded with dumbbells was refused with "Drop the load, or set
        # is_weighted", naming a remedy the tool would not take. A refusal that tells a caller
        # to do something the API cannot express is worse than a plain no, because a model
        # will retry it.
        #
        # Taken from `shape` rather than passed through, because these four do not travel
        # alone: switching to `time` has to null `reps` and set `duration_seconds`, which is
        # sets_measures_one_way's rule one level up, and shape_of is where that already lives.
        # Recomputing the whole shape when any one of them is sent means the quantity always
        # agrees with the measure.
        #
        # `measure` back to its stored form, because Changes.apply compares against `row[]`,
        # which reads the raw column -- a symbol there would differ from the text every time
        # and report a change on every edit that touched anything else.
        def self.reshaped(lift, arguments)
          return {} unless SHAPE_FIELDS.any? { |field| arguments.key?(field) }

          shaped = shape(lift, arguments)
          shaped.merge(measure: Measured.stored(shaped[:measure]))
        end

        # Repointing the movement a percentage is taken of, or clearing it (#295). Null is how
        # a lift goes back to being priced off its own max, which is what the column being
        # absent has always meant -- so the two spellings of "its own" stay one value.
        #
        # A key that was not sent is left alone, the same rule the rest of this tool follows:
        # renaming a lift must not silently repoint what it is priced off.
        def self.reference(context, arguments)
          return {} unless arguments.key?(:percent_of)
          return { percent_of_exercise_id: nil } if arguments[:percent_of].nil?

          { percent_of_exercise_id: Resolver.exercise(context, name: arguments[:percent_of]).id }
        end

        # An edited load lands on a weight the rack can build, the same as one written with
        # the block (#259). Reported honestly by the Changes line above, which describes
        # what was stored rather than what was asked for, so an assistant that sent 152 and
        # reads back "top_weight 155 to 150" can see the rack answered.
        # `arguments` rather than the written slice decides whether there is a load to round,
        # because is_weighted may be arriving in the same call (#305): a lift being loaded for
        # the first time has lift.is_weighted false on the row and true in the arguments, and
        # asking the row would skip the rounding on exactly the edit that introduces a weight.
        def self.round_load(context, lift, attributes, arguments)
          return attributes unless attributes[:top_weight] && arguments.fetch(:is_weighted, lift.is_weighted)

          is_barbell = attributes.fetch(:is_barbell, lift.is_barbell)
          attributes.merge(top_weight: Equipment.loadable_for(context.account_id, attributes[:top_weight], is_barbell:))
        end

        # The arguments that change how a lift progresses. The first two are the price, and
        # the two are the same fact: a percentage is re-read from the estimated max each week,
        # pounds are a starting point the rules step from. Swapping one for the other and
        # leaving the old rule behind writes a row the generator cannot price.
        #
        # is_weighted is the third, and it was the bug #305 found. It does not choose *which*
        # rule applies but whether there is one at all -- unweighted work has no load to
        # decide -- so loading a lift that was written unweighted has to recompute the rule
        # even though neither price key moved on its own.
        REPRICES = %i[top_weight percent_of_max is_weighted].freeze

        # Read off `arguments` and not the written slice, which is what made the two disagree:
        # the slice carries no is_weighted, so `merged` saw the old value and decided the lift
        # was still unweighted -- progression nil -- while `reshaped` wrote is_weighted true
        # beside it. That row fails program_lifts_weight_matches_progression, as a check
        # violation rather than as a refusal anybody could read.
        def self.repriced(lift, arguments)
          return {} unless REPRICES.any? { |field| arguments.key?(field) }

          { progression: ProgramWriter.progression_for(merged(lift, arguments), shape(lift, arguments)) }
        end

        # Position is applied by renumbering the whole day rather than written as a
        # column, so it is reported separately from the fields that are.
        def self.move(lift, position)
          return {} if position.nil?

          before = lift.position
          ProgramWriter.reposition(lift, position)
          before == lift.position ? {} : { position: { from: before, to: lift.position } }
        end

        # The bounds every lift is written against, plus the rule that a lift says what it
        # weighs in exactly one way -- checked against the row as it will be, so an edit
        # that sets a percentage without clearing the pounds is refused rather than
        # written into a state the generator would have to guess its way out of.
        def self.check(lift, attributes)
          ProgramWriter.check_load(merged(lift, attributes), shape(lift, attributes))
        end

        # The row as it will be, including how it is done. The three shape columns are
        # spelled out rather than left to the movement's defaults, because this is an edit
        # to a lift that has already answered them and an unrelated change must not quietly
        # reset the answer to whatever the movement usually does.
        def self.merged(lift, attributes)
          { sets: lift.sets, reps: lift.reps, duration_seconds: lift.duration_seconds,
            top_weight: lift.top_weight, percent_of_max: lift.percent_of_max,
            is_weighted: lift.is_weighted, measure: lift.measure,
            is_per_side: lift.is_per_side }.merge(attributes)
        end

        def self.shape(lift, attributes)
          ProgramWriter.shape_of(merged(lift, attributes), lift.exercise)
        end
      end
    end
  end
end

