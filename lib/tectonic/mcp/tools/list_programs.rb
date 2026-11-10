# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # The account's training blocks, newest first, as summaries: enough to say what a
      # lifter is on and which week of it, without pulling every lift of every week.
      #
      # Bounded like list_workouts (directory review: responses reasonably sized). The total is
      # still reported, so a lifter with forty blocks is told the twenty shown are not all.
      class ListPrograms < Tool
        DEFAULT_LIMIT = 20
        MAX_LIMIT = 100

        tool_name 'list_programs'
        title 'List training blocks'
        description "The account's training blocks, newest first, with start date, length in " \
                    'weeks and which week today falls in; get_program reads one in full. ' \
                    "limit defaults to #{DEFAULT_LIMIT}, at most #{MAX_LIMIT}."
        scope :read
        input_schema(type: 'object', properties: { limit: { type: 'integer' } }, additionalProperties: false)

        def self.perform(context:, arguments:)
          newest = context.programs.order(Sequel.desc(:start_date), Sequel.desc(:id))
          total = newest.count
          programs = newest.limit(limit_for(arguments)).all
          views = programs.map { |block| ProgramView.program(block) }
          ok(sentence(programs.size, total), structured: { programs: views, shown: programs.size, total: })
        end

        def self.limit_for(arguments)
          (arguments[:limit] || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        end

        def self.sentence(shown, total)
          return "You have #{total} program(s)." if shown == total

          "You have #{total} program(s); showing the newest #{shown}. Raise limit up to #{MAX_LIMIT} for more."
        end
      end
    end
  end
end

