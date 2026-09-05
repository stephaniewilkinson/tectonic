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
        title 'Read a training block'
        description 'Read one training block in full: its weeks, the days in each week ' \
                    'with the dates they fall on, and every lift in order with its sets, ' \
                    'reps and load. Returns the ids the program edit tools take. ' \
                    'Get a program_id from list_programs.'
        scope :read
        input_schema(
          type: 'object',
          properties: { program_id: { type: 'integer' } },
          required: ['program_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          block = ProgramFinder.program(context, arguments[:program_id])
          view = ProgramView.full_program(block)
          ok([headline(view), *view[:weeks].flat_map { |week| week_lines(week) }].join("\n"), structured: view)
        end

        # The prose was one sentence -- "Block 0: 4 week(s) from 2026-08-24." -- under a
        # description promising "the ids the program edit tools take". It returned no ids
        # at all, and a model that reads only the text (which many connectors are) had
        # nowhere to go from there: the route to a handle is search then fetch, and nothing
        # said so. #262.
        #
        # The structured payload has always carried all of this. What is written here is
        # the same tree flattened, because the two halves of a response should answer the
        # same question and only one of them was.
        def self.headline(view)
          shape = [("currently week #{view[:current_week]}" if view[:current_week]),
                   (view[:is_ascending] ? 'ascending sets' : 'flat sets'),
                   ("preferred reps #{view[:preferred_reps]}" if view[:preferred_reps])].compact
          "#{view[:name]} (program #{view[:id]}): #{view[:weeks].length} week(s) from " \
            "#{view[:start_date]}, #{shape.join(', ')}."
        end

        def self.week_lines(week)
          ["Week #{week[:number]} (week id #{week[:id]}) from #{week[:start_date]}" \
           "#{' -- deload' if week[:is_deload]}",
           *week[:days].flat_map { |day| day_lines(day) }]
        end

        def self.day_lines(day)
          ["  #{day[:weekday_name]} #{day[:date]}#{", #{day[:focus]}" if day[:focus]} (day id #{day[:id]})",
           *day[:lifts].map { |lift| "    lift #{lift[:id]}: #{lift_line(lift)}" }]
        end

        # Sets, reps and load, which is what the description promises of a lift. A lift
        # priced as a percentage says so rather than showing a blank where pounds would be,
        # and one carrying no load at all -- bodyweight, banded -- says nothing rather than
        # implying zero.
        #
        # The target effort follows the load rather than preceding it (#265), because the
        # load is what identifies the lift when this is skimmed and because a prescription
        # reads as a weight first and a difficulty second. Only where there is one: most
        # lifts carry none, and ", target RPE" on every line would be noise on all of them.
        # Whose max a percentage is of. "max" unqualified where it is the lift's own, which
        # is the ordinary case and reads the way it always did; named where it is another
        # movement's, because "70% of max" on a deficit deadlift is the sentence #295 is
        # about and it means two different loads depending on which max was meant.
        def self.whose_max(lift)
          lift[:percent_of] ? "#{lift[:percent_of]} max" : 'max'
        end

        def self.lift_line(lift)
          load = if lift[:top_weight] then " @ #{lift[:top_weight]}"
                 elsif lift[:percent_of_max] then " @ #{lift[:percent_of_max]}% of #{whose_max(lift)}"
                 else ''
                 end
          target = lift[:target_rpe] ? ", target RPE #{lift[:target_rpe]}" : ''
          "#{lift[:exercise]} #{lift[:sets]}x#{lift[:reps]}#{load}#{target}#{" (#{lift[:note]})" if lift[:note]}"
        end
      end
    end
  end
end

