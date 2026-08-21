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

        tool_name 'update_program_lift'
        description 'Change a prescribed lift: sets, reps, top_weight or percent_of_max, ' \
                    'the exercise it is, whether it is the main work, or its position in ' \
                    'the day (0 is first). Send only what changes. To swap how the load is ' \
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
            is_barbell: { type: 'boolean' }, note: { type: 'string' }
          },
          required: ['program_lift_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          lift = ProgramFinder.lift(context, arguments[:program_lift_id])
          changed = DB.transaction { revise(context, lift, arguments) }
          ok("#{lift.exercise.name}: #{Changes.describe(changed)}.",
             structured: ProgramView.lift(lift.refresh).merge(changed:))
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
          attributes = arguments.slice(:sets, :reps, :top_weight, :percent_of_max, :is_main, :is_barbell, :note)
          return attributes unless arguments[:exercise]

          exercise = Resolver.exercise(context, name: arguments[:exercise])
          return attributes if exercise.id == lift.exercise_id

          { exercise_id: exercise.id, is_barbell: exercise.barbell? }.merge(attributes)
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
          ProgramWriter.check_load(merged(lift, attributes))
        end

        def self.merged(lift, attributes)
          { sets: lift.sets, reps: lift.reps, top_weight: lift.top_weight,
            percent_of_max: lift.percent_of_max }.merge(attributes)
        end
      end
    end
  end
end

