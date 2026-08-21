# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative '../../program_generator'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Finding a program object for a request. Every lookup goes through the
      # account-scoped datasets on the context, so an id belonging to someone else's
      # block resolves to nothing rather than to their plan -- the same guarantee the
      # set and workout tools get, reached the same way. A miss is a refusal naming what
      # was looked for, because a model that guessed an id can act on being told so and
      # can do nothing with a silent nil.
      module ProgramFinder
        module_function

        def program(context, id)
          context.programs.where(id:).first || missing('program', id)
        end

        def day(context, id)
          context.program_days.where(id:).first || missing('program day', id)
        end

        def lift(context, id)
          context.program_lifts.where(id:).first || missing('program lift', id)
        end

        # A week by its number within a block, which is how a model refers to one: week
        # 2 of the block it is looking at, never a week id it has to have seen first.
        def week(context, program, number)
          context.program_weeks.where(program_id: program.id, number:).first ||
            (raise Tool::Refusal, "Program #{program.id} has no week #{number}; it has #{program.weeks}.")
        end

        def missing(kind, id)
          raise Tool::Refusal, "No #{kind} with id #{id.inspect} on this account."
        end
      end

      # How a program and its parts read back to a model. A block is described the way it
      # is trained -- weeks in order, days in weekday order, lifts in the position they
      # were written -- and every day carries the date it actually falls on, because a
      # weekday alone is not something a model can tell a user about.
      module ProgramView
        module_function

        def program(block)
          { id: block.id, name: block.name, block: block.block,
            start_date: block.start_date.strftime('%Y-%m-%d'), weeks: block.weeks,
            current_week: block.week_on&.number, preferred_reps: block.preferred_reps,
            is_ascending: block.is_ascending }
        end

        # The whole block, which is what an assistant asked to review or revise a plan
        # needs in one call rather than a walk down three levels of ids.
        def full_program(block)
          program(block).merge(weeks: block.program_weeks.map { |row| week(row) })
        end

        def week(row)
          { id: row.id, number: row.number, is_deload: row.is_deload, notes: row.notes,
            start_date: row.start_date.strftime('%Y-%m-%d'),
            days: row.program_days.sort_by(&:weekday).map { |row_day| day(row_day, row) } }
        end

        def day(row, week_row = nil)
          { id: row.id, weekday: row.weekday, weekday_name: Date::DAYNAMES[row.weekday],
            focus: row.focus, date: week_row&.date_for(row.weekday)&.strftime('%Y-%m-%d'),
            lifts: row.program_lifts.sort_by(&:position).map { |row_lift| lift(row_lift) } }
        end

        def lift(row)
          { id: row.id, position: row.position, exercise: row.exercise&.name,
            exercise_id: row.exercise_id, sets: row.sets, reps: row.reps,
            top_weight: row.top_weight, percent_of_max: row.percent_of_max,
            is_barbell: row.is_barbell, is_main: row.is_main, note: row.note }
        end
      end
    end
  end
end

