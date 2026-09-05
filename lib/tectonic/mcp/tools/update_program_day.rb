# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Moves a training day to another weekday, or renames what it is for. Small, and
      # separate from the lift tools, because moving a session is a scheduling change and
      # changing its work is a programming one -- a lifter asks for them separately and
      # they are worth being able to do separately.
      class UpdateProgramDay < Tool
        tool_name 'update_program_day'
        title 'Edit a training day'
        description "Change a training day's weekday (0 Sunday to 6 Saturday) or its focus. " \
                    'Moving it re-dates the session in every week it is written into. ' \
                    'Sessions already generated keep the date they were generated on.'
        scope :write
        input_schema(
          type: 'object',
          properties: { program_day_id: { type: 'integer' }, weekday: { type: 'integer' },
                        focus: { type: 'string' } },
          required: ['program_day_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          day = ProgramFinder.day(context, arguments[:program_day_id])
          attributes = arguments.slice(:weekday, :focus)
          ProgramWriter.weekday(attributes[:weekday]) if attributes.key?(:weekday)
          changed = Changes.apply(day, attributes)
          week = day.program_week
          ok("#{Date::DAYNAMES[day.weekday]} of week #{week.number}: #{Changes.describe(changed)}.",
             structured: ProgramView.day(day.refresh, week).merge(changed:))
        end
      end
    end
  end
end

