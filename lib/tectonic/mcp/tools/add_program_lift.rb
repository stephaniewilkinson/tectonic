# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Adds one lift to a day that already exists, for the "and put some rows in after
      # the bench" case. Everything about how a lift is written -- the bounds, the one of
      # top_weight or percent_of_max rule, taking the barbell flag off the movement -- is
      # the writer's, so a lift added here is indistinguishable from one written with the
      # block it belongs to.
      class AddProgramLift < Tool
        tool_name 'add_program_lift'
        title 'Add a lift to a day'
        description 'Add a lift to a training day. Give either top_weight in pounds or ' \
                    'percent_of_max, or is_weighted false for work carrying no external ' \
                    'load. measure is reps or time; a timed lift gives duration_seconds ' \
                    'instead of reps. is_per_side says the count is per side. Each defaults ' \
                    'to how the movement is usually done. target_rpe, 1 to 10, is the ' \
                    'effort the working sets are meant to be taken at -- how autoregulated ' \
                    'programming is written, and the better instruction than a percentage ' \
                    'coming off a layoff. It belongs only on a loaded lift counted in reps. ' \
                    'percent_of names a different movement whose max the percentage is of: ' \
                    'a deficit deadlift written at 70% of the competition deadlift, or ' \
                    'supplemental work off the main lift. It defaults to the lift itself. ' \
                    'It goes last in the day unless position says otherwise.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            program_day_id: { type: 'integer' }, exercise: { type: 'string' },
            sets: { type: 'integer' }, reps: { type: 'integer' },
            top_weight: { type: 'number' }, percent_of_max: { type: 'integer' },
            is_weighted: { type: 'boolean' }, measure: { type: 'string', enum: %w[reps time] },
            is_per_side: { type: 'boolean' }, duration_seconds: { type: 'integer' },
            position: { type: 'integer' }, is_main: { type: 'boolean' },
            is_barbell: { type: 'boolean' }, target_rpe: { type: 'integer' },
            percent_of: { type: 'string' }, note: { type: 'string' }
          },
          required: %w[program_day_id exercise sets], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          day = ProgramFinder.day(context, arguments[:program_day_id])
          lift = DB.transaction { write(context, day, arguments) }
          refreshed = SessionRefresh.apply(day)
          ok(added(lift, day, refreshed), structured: ProgramView.lift(lift).merge(session: refreshed.to_s))
        end

        def self.added(lift, day, refreshed)
          "Added #{lift.exercise.name} #{lift.sets}x#{lift.reps} to #{Date::DAYNAMES[day.weekday]} " \
            "at position #{lift.position}.#{SessionRefresh.sentence(refreshed, day)}"
        end

        def self.write(context, day, arguments)
          lift = ProgramWriter.lift(context, day, arguments)
          ProgramWriter.reposition(lift, arguments[:position]) if arguments[:position]
          lift
        end
      end
    end
  end
end

