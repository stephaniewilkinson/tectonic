# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # The account's training blocks, newest first, as summaries: enough to say what a
      # lifter is on and which week of it, without pulling every lift of every week.
      class ListPrograms < Tool
        tool_name 'list_programs'
        title 'List training blocks'
        description "List the account's training blocks with their start date, length in " \
                    'weeks, and which week of the block today falls in. Use get_program ' \
                    'for one block in full.'
        scope :read
        input_schema(type: 'object', properties: {}, additionalProperties: false)

        def self.perform(context:, **)
          programs = context.programs.order(Sequel.desc(:start_date), Sequel.desc(:id)).all
          ok("You have #{programs.size} program(s).",
             structured: { programs: programs.map { |block| ProgramView.program(block) } })
        end
      end
    end
  end
end

