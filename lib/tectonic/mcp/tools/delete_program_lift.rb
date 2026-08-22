# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Removes a prescribed lift from a day.
      #
      # A real delete. A program lift is a plan, not a record of training: nothing points
      # at it, the workouts it has already produced are ordinary set rows that stand on
      # their own, and a lift kept as a tombstone would have to be filtered out of every
      # read of the plan for no gain. What it was is returned, so a model that has just
      # deleted the wrong one can put it straight back with add_program_lift.
      class DeleteProgramLift < Tool
        tool_name 'delete_program_lift'
        description 'Remove a lift from a training day. Returns what was removed, so it ' \
                    'can be added back if it was the wrong one. Sessions already generated ' \
                    'from this day are not touched.'
        scope :write
        input_schema(
          type: 'object',
          properties: { program_lift_id: { type: 'integer' } },
          required: ['program_lift_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          lift = ProgramFinder.lift(context, arguments[:program_lift_id])
          removed = ProgramView.lift(lift)
          day = lift.program_day
          DB.transaction { close_gap(lift, day) }
          refreshed = SessionRefresh.apply(day)
          ok("Removed #{removed[:exercise]} #{removed[:sets]}x#{removed[:reps]} from " \
             "#{Date::DAYNAMES[day.weekday]}.#{SessionRefresh.sentence(refreshed, day)}",
             structured: { removed:, session: refreshed.to_s })
        end

        # The lift goes and the ones after it close up, so positions stay 0..n-1 and the
        # session order after a deletion reads the way it did before one.
        def self.close_gap(lift, day)
          lift.delete
          day.program_lifts.sort_by(&:position).each_with_index do |row, index|
            row.update(position: index) if row.position != index
          end
        end
      end
    end
  end
end

