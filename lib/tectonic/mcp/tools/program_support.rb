# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative '../../program_generator'
require_relative 'support'
require_relative '../../setup'

class Tectonic < Roda
  module MCP
    module Tools
      # Carrying an edit through to the session the plan already produced. Editing a
      # prescription used to leave that session exactly as it was, so the only way to
      # apply a change was to know generation had already happened and then fix every set
      # by hand -- and nothing anywhere said that it had.
      #
      # A completed set is left alone. Once a lifter has answered a prescription that row is a
      # record of what happened rather than a plan to be revised, and the sets around it are
      # rewritten regardless -- the protected unit is the set, not the day it sits in (#407).
      # What could not follow is reported rather than raised: the edit to the plan is still
      # correct and still wanted, and it is only part of the session that stood still.
      module SessionRefresh
        module_function

        def apply(day)
          ProgramGenerator.new(day.program_week.program).refresh(day)
        end

        # What happened to the session, as a sentence to append to whatever the tool was
        # already saying. Silence where there was no session to touch, because a block
        # edited before anyone generated it is the ordinary case and needs no remark.
        # The counts are the point of the :partly case (#407). "The session was left alone"
        # was the whole answer when one lifted set stopped the day, and it is no longer true:
        # a session can now be half rewritten, and a model that is not told how much was
        # rewritten and how much was kept cannot tell the lifter what their session is.
        def sentence(refresh, day)
          named = Date::DAYNAMES[day.weekday]
          case refresh.outcome
          when :rewritten then " The planned session on #{named} was rewritten to match."
          when :partly then partly(refresh, named)
          when :emptied then emptied(refresh, named)
          when :lifted then " The #{named} session has lifted sets in it, so it was left alone."
          else ''
          end
        end

        def partly(refresh, named)
          " The #{named} session was rewritten around what had already been lifted: " \
            "#{refresh.written} #{refresh.written == 1 ? 'set' : 'sets'} updated, " \
            "#{refresh.kept} left because #{refresh.kept == 1 ? 'it was' : 'they were'} completed."
        end

        # A session the plan no longer asks anything unfinished of. #441.
        #
        # It used to fall into :lifted and be reported as left alone, which was the opposite of
        # what had happened to it -- the planned sets were deleted and nothing was written back
        # because there was nothing left to write. Saying what came out is the whole point: the
        # lifter's next question is where the movement went, and "left alone" sends them
        # looking for it in the session it was just taken out of.
        def emptied(refresh, named)
          " The #{named} session had #{refresh.removed} planned " \
            "#{refresh.removed == 1 ? 'set' : 'sets'} taken out and nothing left to put back. " \
            "The #{refresh.kept} #{refresh.kept == 1 ? 'set' : 'sets'} already lifted " \
            "#{refresh.kept == 1 ? 'stays' : 'stay'} as #{refresh.kept == 1 ? 'it is' : 'they are'}."
        end
      end

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

        # The same lift in every week of its block, this one included, in week order: the lift
        # of the same movement on the same weekday, and where a day holds that movement more
        # than once, the one in the same place among them.
        #
        # For `every_week` (the audit log, 2026-09): removing five movements from a three-week
        # block took fifteen delete_program_lift calls, and a note or a weight changed "for the
        # block" was the same call once per week. A block is written by copying a week, so the
        # copies are findable by what they are rather than by an id nobody has seen.
        def counterparts(lift)
          day = lift.program_day
          week = day.program_week
          rank = rank_of(lift, day)
          week.program.program_weeks.sort_by(&:number).filter_map do |other|
            same_day = other.program_days.find { |candidate| candidate.weekday == day.weekday }
            same_day && same_movement(same_day, lift.exercise_id)[rank]
          end
        end

        def rank_of(lift, day) = same_movement(day, lift.exercise_id).index { |row| row.id == lift.id }

        def same_movement(day, exercise_id)
          day.program_lifts.select { |row| row.exercise_id == exercise_id }.sort_by(&:position)
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
            is_ascending: block.is_ascending,
            # How long a session of this block is meant to take, or null where the block was
            # not written against a clock -- which is most of them, and which is why nothing
            # here defaults it. #408.
            time_budget_minutes: block.time_budget_minutes }
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

        # top_weight through the presenter, which is #256 in the one place that issue did
        # not look. It found the scientific notation in the prose and reported the
        # structured payload as already correct -- true of a set, whose weight goes through
        # Presenter.weight in view_set, and not true here. Migration 012 made this column
        # numeric(7,2) as well, so a program lift's load reached structuredContent as the
        # JSON *string* "0.155e3" where a client had every reason to expect the number 155.
        # The movement a percentage is taken of, by name, and absent where it is the lift's
        # own -- which is the ordinary case and the one that should read as it always did.
        def reference_of(row)
          { percent_of: Exercise[row.percent_of_exercise_id]&.name }
        end

        def lift(row)
          { id: row.id, position: row.position, exercise: row.exercise&.name,
            exercise_id: row.exercise_id, sets: row.sets, reps: row.reps,
            is_barbell: row.is_barbell, is_main: row.is_main, note: row.note }
            .merge(prescription_of(row)).merge(reference_of(row))
        end

        # What the lift asks for, as against what it is. The load and the three instructions
        # that travel onto the rows the generator writes -- an effort to take the working
        # sets at, a rest to take between them, and whether they are done under commands.
        #
        # is_commanded is here rather than beside is_barbell in `lift` above, and the line is
        # worth drawing: the flags there say what the lift *is* and this says what the block
        # is *asking for*. Reading a plan back without it would hide the one instruction a
        # meet-prep block is written around. #311.
        def prescription_of(row)
          { top_weight: Presenter.weight(row.top_weight), percent_of_max: row.percent_of_max,
            target_rpe: row.target_rpe, rest_seconds: row.rest_seconds,
            is_commanded: row.is_commanded }.merge(Setup.of(row))
        end
      end
    end
  end
end

