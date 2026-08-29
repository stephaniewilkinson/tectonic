# frozen_string_literal: true

require_relative '../tool'
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # Removes a training block: the block, its weeks, its days and every lift in them.
      #
      # There was no way to do this, which #261 ran into by leaving a throwaway `zz-probe`
      # block behind while testing API validation -- permanent, and in every list_programs
      # for as long as the account exists. It also closed the only workaround for #260:
      # with nothing able to change a block's settings, rebuilding it was the answer, and
      # rebuilding left the old one behind forever.
      #
      # **The sessions it wrote are kept.** That is the decision worth stating, because the
      # other reading is defensible and wrong. A generated workout is not part of the plan;
      # it is a day somebody trained, and the block is only where its numbers came from.
      # Deleting a block in March should not delete February's training. So the workouts
      # have their program_day_id cleared and become ordinary hand-logged sessions -- the
      # column is nullable, which is what makes this a write rather than a migration, and a
      # workout without one is exactly what a session typed in by hand already is.
      #
      # The cost of that is small and worth naming: Workout#status reads program_day_id, so
      # an orphaned session that was never trained stops reading as "skipped" and starts
      # reading as history. That is the same fall-through a hand-logged session takes, and
      # the comment there gives the reason -- it exists because a person logged it.
      class DeleteProgram < Tool
        tool_name 'delete_program'
        description 'Delete a training block and everything prescribed in it. Sessions it ' \
                    'already generated are kept and become hand-logged workouts, since ' \
                    'those days were trained. A block that has generated sessions needs ' \
                    'confirm true.'
        scope :write
        input_schema(
          type: 'object',
          properties: { program_id: { type: 'integer' }, confirm: { type: 'boolean' } },
          required: ['program_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          program = ProgramFinder.program(context, arguments[:program_id])
          removed = ProgramView.program(program)
          days = day_ids(program)
          sessions = Workout.where(program_day_id: days).count
          refuse_generated(removed, sessions, arguments)
          DB.transaction { destroy(program, days) }
          ok(sentence(removed, sessions), structured: { removed:, orphaned_workouts: sessions })
        end

        # Children before parents, which the foreign keys require. The workouts are let go
        # rather than deleted, so they are updated rather than appearing in this list.
        def self.destroy(program, days)
          Workout.where(program_day_id: days).update(program_day_id: nil)
          ProgramLift.where(program_day_id: days).delete
          ProgramDay.where(id: days).delete
          ProgramWeek.where(program_id: program.id).delete
          program.delete
        end

        def self.day_ids(program)
          ProgramDay.where(program_week_id: program.program_weeks_dataset.select(:id)).select_map(:id)
        end

        # A block nobody has generated a week of is a plan and nothing else, so removing it
        # costs nothing and needs no ceremony -- which is the `zz-probe` case exactly. One
        # that has written sessions is a different thing to delete, even though those
        # sessions survive it, because the link between them and the plan does not.
        def self.refuse_generated(removed, sessions, arguments)
          return if sessions.zero? || arguments[:confirm]

          raise Tool::Refusal, "#{removed[:name]} has generated #{sessions} session(s). Deleting " \
                               'the block keeps them as hand-logged workouts but loses which ' \
                               'block they came from. Send confirm true if the user asked for it.'
        end

        def self.sentence(removed, sessions)
          kept = if sessions.zero?
                   'It had generated no sessions.'
                 else
                   "#{sessions} session(s) it generated were kept as hand-logged workouts."
                 end
          "Deleted #{removed[:name]}, #{removed[:weeks]} week(s) from #{removed[:start_date]}. #{kept}"
        end
      end
    end
  end
end

