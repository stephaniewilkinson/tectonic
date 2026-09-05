# frozen_string_literal: true

require_relative '../tool'
# CreateProgram::LIFT, so a lift is described to a model the same way wherever it is written.
require_relative 'create_program'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Adds a training day to one week of a block, with its lifts in the same call. The
      # lifts are nested for the same reason create_program nests everything: a day is
      # written as a whole thought -- "Thursday is deadlifts and rows" -- and a day that
      # exists with none of its work in it is a thing a lifter can open and be confused by.
      class AddProgramDay < Tool
        tool_name 'add_program_day'
        title 'Add a training day'
        description 'Add a training day to one week of a block, with its lifts. weekday is ' \
                    '0 for Sunday through 6 for Saturday; the date it falls on follows from ' \
                    "the block's start date. Each lift gives either top_weight or percent_of_max."
        scope :write
        input_schema(
          type: 'object',
          properties: { program_id: { type: 'integer' }, week: { type: 'integer' },
                        weekday: { type: 'integer' }, focus: { type: 'string' },
                        lifts: { type: 'array', items: CreateProgram::LIFT } },
          required: %w[program_id week weekday], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          program = ProgramFinder.program(context, arguments[:program_id])
          week = ProgramFinder.week(context, program, arguments[:week])
          day = DB.transaction { ProgramWriter.day(context, week, arguments) }
          ok("Added #{Date::DAYNAMES[day.weekday]} to week #{week.number} of #{program.name} " \
             "(#{week.date_for(day.weekday)}), with #{day.program_lifts.count} lift(s).",
             structured: ProgramView.day(day, week))
        end
      end
    end
  end
end

