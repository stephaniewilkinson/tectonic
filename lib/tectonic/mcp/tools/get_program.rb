# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # One block in full: every week, every day of it in weekday order with the date it
      # falls on, and every lift in the position it was written. This is the call an
      # assistant makes before revising a plan, so it hands back the ids the edit tools
      # take -- a lift cannot be changed by a model that has only ever seen its name.
      class GetProgram < Tool
        tool_name 'get_program'
        description 'Read one training block in full: its weeks, the days in each week ' \
                    'with the dates they fall on, and every lift in order with its sets, ' \
                    'reps and load. Returns the ids the program edit tools take.'
        scope :read
        input_schema(
          type: 'object',
          properties: { program_id: { type: 'integer' } },
          required: ['program_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          block = ProgramFinder.program(context, arguments[:program_id])
          ok("#{block.name}: #{block.weeks} week(s) from #{block.start_date}.",
             structured: ProgramView.full_program(block))
        end
      end
    end
  end
end

