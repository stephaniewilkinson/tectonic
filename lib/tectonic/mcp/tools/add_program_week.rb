# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Extends a block by a week, optionally copying an existing week's days and lifts.
      #
      # The copy is the reason this exists rather than a bare insert. Week four of a block
      # is almost always week three with different numbers, and rebuilding it lift by lift
      # is twenty calls to say "the same again". Copying then editing the few loads that
      # moved is two or three.
      class AddProgramWeek < Tool
        tool_name 'add_program_week'
        title 'Add a week to a block'
        description 'Add a week to the end of a block, or at a given number. Pass ' \
                    "copy_from_week to duplicate that week's days and lifts into it, then " \
                    'edit the loads that differ. Mark is_deload for a lighter week.'
        scope :write
        input_schema(
          type: 'object',
          properties: { program_id: { type: 'integer' }, number: { type: 'integer' },
                        copy_from_week: { type: 'integer' }, is_deload: { type: 'boolean' },
                        notes: { type: 'string' } },
          required: ['program_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          program = ProgramFinder.program(context, arguments[:program_id])
          week = DB.transaction { write(context, program, arguments) }
          ok("Added week #{week.number} to #{program.name}, starting #{week.start_date}.",
             structured: ProgramView.week(week))
        end

        def self.write(context, program, arguments)
          number = arguments[:number] || (program.weeks + 1)
          refuse_taken(context, program, number)
          week = ProgramWeek.create(program_id: program.id, number:,
                                    is_deload: arguments.fetch(:is_deload, false), notes: arguments[:notes])
          copy_days(context, program, week, arguments[:copy_from_week])
          week
        end

        # The days of the source week, rewritten under the new one. Lifts are rebuilt
        # through the same writer every other path uses rather than copied column by
        # column, so a copied lift is exactly what a written one would have been.
        def self.copy_days(context, program, week, source_number)
          return unless source_number

          ProgramFinder.week(context, program, source_number).program_days.each do |day|
            ProgramWriter.day(context, week, weekday: day.weekday, focus: day.focus,
                                             lifts: day.program_lifts.sort_by(&:position).map { |l| copied(l) })
          end
        end

        def self.copied(lift)
          { exercise: lift.exercise.name, sets: lift.sets, reps: lift.reps, top_weight: lift.top_weight,
            percent_of_max: lift.percent_of_max, is_main: lift.is_main, is_barbell: lift.is_barbell,
            note: lift.note }
        end

        def self.refuse_taken(context, program, number)
          return unless context.program_weeks.where(program_id: program.id, number:).first

          raise Tool::Refusal, "#{program.name} already has a week #{number}. " \
                               'Add it at another number, or edit the week that is there.'
        end
      end
    end
  end
end

