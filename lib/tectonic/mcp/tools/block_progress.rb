# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../training_max'
require_relative '../../goal'

class Tectonic < Roda
  module MCP
    module Tools
      # What each block opened at, movement by movement, against what you are aiming for.
      # #308: "am I on pace", which is the question a competitive lifter actually has and the
      # one nothing in the app could answer.
      #
      # `list_programs` showed blocks and nothing related them, so a block was an island.
      # Three things were missing and only one of them was data: a target to be on pace *for*
      # (now `account_goals`), a way to say what a past block was really generated against
      # (now `account_training_max_statements`), and this, which is the read over both and
      # needs nothing of its own.
      #
      # **Movement-first, blocks nested.** Block-first was the other shape and it buries the
      # thing being asked about: "squat 405, 425, 445, 445" down one row is a trend a reader
      # sees at a glance, where the same numbers spread across four block objects have to be
      # gathered before they mean anything. The blocks stay in order inside each movement, so
      # nothing is lost by nesting them.
      #
      # **Sequencing is not modelled and does not need to be.** `start_date` already orders
      # blocks, `list_programs` already sorts by it, and a `follows_program_id` would be a
      # chain to maintain and get wrong. It would earn its place only if two blocks could
      # overlap or run in parallel, which nothing here does.
      #
      # **Nothing computes "behind schedule".** The goal, the deadline, the gap and the
      # openers are reported and the assistant judges. That is #263's split, and it matters
      # more here than it did for session length: pace on a barbell is not linear, a peaking
      # block moves a max in a way a hypertrophy block deliberately does not, and pounds
      # divided by weeks would call a correctly-run offseason a failure every time.
      class BlockProgress < Tool
        DEFAULT_BLOCKS = 6
        MAX_BLOCKS = 24

        tool_name 'block_progress'

        title 'Block progress'
        description 'What each training block opened at, movement by movement, against any ' \
                    'goal set for that movement. Answers "am I on pace": it returns the ' \
                    'training max each block was generated against, newest block first, ' \
                    'plus the goal, its deadline and how far there is to go. Narrow to one ' \
                    'movement with exercise, and how far back with blocks. Movements carrying ' \
                    'no max, no goal and no opener are left out, since a block is mostly ' \
                    'accessory work with nothing to compare; naming one in exercise reports ' \
                    'it either way. Each block also carries commanded_reps, the reps done to ' \
                    "a referee's timing in it, for training the pause a meet judges. It " \
                    'reports the numbers and does not judge whether they are enough.'
        scope :read
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, blocks: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          blocks = recent(context, arguments)
          movements = subjects(context, blocks, arguments)
          rows = reportable(movements.map { |exercise| movement(context, exercise, blocks) }, arguments)
          commanded = commanded_reps(context, blocks)
          ok("#{summary(rows, blocks)}#{commanded_sentence(commanded, blocks)}",
             structured: { movements: rows,
                           blocks: blocks.map { |b| named(b).merge(commanded_reps: commanded[b.id] || 0) } })
        end

        # How many commanded reps each block contains. #453.
        #
        # `is_commanded` has been on sets since 031 and get_workout's own comment says why it
        # was added: the flag "is the only thing on the row saying the set was done to a
        # referee's timing rather than the lifter's, and a session read back without it cannot
        # answer 'how many commanded reps did this block contain' -- which is the question the
        # column was added for". Nothing answered it. The flag was readable one session at a
        # time and the block-level total, which is the number #453 asks for, did not exist.
        #
        # Reps rather than sets, because that is what #453 asks for and it is the honest unit:
        # a paused triple is three commands and a paused single is one, and a lifter training
        # for a meet is counting the times they have waited for "press".
        #
        # Per-side reps count twice, on Volume::WORKED_REPS' rule -- eight per side is sixteen
        # commands. Warmups are in, unlike Volume: a commanded warmup single is command
        # practice, which is the whole point of doing one.
        #
        # One query for every block rather than one per block, walking the chain a session
        # hangs off: a set belongs to a workout, which names the program day it was generated
        # from, which belongs to a week, which belongs to the block. Scoped by `context.sets`,
        # so another account's training is unreachable rather than merely filtered out.
        BLOCK_OF_A_SET = Sequel[:program_weeks][:program_id]

        def self.commanded_reps(context, blocks)
          commanded(context).where(BLOCK_OF_A_SET => blocks.map(&:id))
                            .group(BLOCK_OF_A_SET)
                            .select_hash(BLOCK_OF_A_SET, COMMANDED_REPS)
        end

        def self.commanded(context)
          context.sets.where(is_commanded: true, is_completed: true)
                 .join(:workouts, id: :workout_id)
                 .join(:program_days, id: Sequel[:workouts][:program_day_id])
                 .join(:program_weeks, id: Sequel[:program_days][:program_week_id])
        end

        # Doubled for a per-side count, on Volume::WORKED_REPS' argument: eight reps per side
        # is sixteen reps of work and sixteen commands.
        COMMANDED_REPS = Sequel.as(
          Sequel.function(:sum,
                          Sequel.lit('CASE WHEN sets.is_per_side THEN sets.reps * 2 ELSE sets.reps END')),
          :reps
        )

        # Said only where there are any, and named by block rather than by id. A block with
        # none is every block trained so far, and "0 commanded reps" on every answer would be
        # the noise `aim` refuses to print about goals.
        def self.commanded_sentence(commanded, blocks)
          trained = blocks.reject { |block| commanded[block.id].to_i.zero? }
          return '' if trained.empty?

          counted = trained.map { |block| "#{block.name} #{commanded[block.id]}" }.join(', ')
          "\nCommanded reps, for the timing a meet judges: #{counted}."
        end

        # The movements with something to say, which on a real account is a small fraction of
        # the ones prescribed. #450.
        #
        # `subjects` takes everything in the blocks being reported, and most of a block is
        # accessory work carrying no training max and no goal -- banded clamshells, dead bugs,
        # bike intervals. Those came back as rows of nulls: on the reporting account, **thirty
        # of thirty-three movements**, with the three lifts the question is actually about
        # buried among them.
        #
        # That is the argument `aim` already makes one method down about a clause -- "a tool
        # that appended 'no goal set' to every row would bury the rows that have one" -- and it
        # is truer of a whole row than of a phrase. A reader asking "am I on pace" wants the
        # squat, the bench and the deadlift.
        #
        # A row survives on any of the three: a max today, a goal, or an opener in some block.
        # The goal clause matters on its own and is why this is not simply "has a max" -- #308
        # put accessories with targets in deliberately, so a lifter bringing one up before it
        # is in any block is not met with silence.
        #
        # Never filtered when the caller named a movement. Asking about the clamshell and being
        # told nothing at all is worse than being told it has nothing on it, and the empty
        # answer is the true one to that question.
        def self.reportable(rows, arguments)
          return rows if arguments[:exercise]

          rows.select { |row| worth_saying?(row) }
        end

        def self.worth_saying?(row)
          row.dig(:training_max, :pounds) || row[:goal] ||
            row[:opened_at].any? { |opener| opener[:pounds] }
        end

        # The blocks to report on, newest first, which is `list_programs`' own order.
        def self.recent(context, arguments)
          limit = (arguments[:blocks] || DEFAULT_BLOCKS).clamp(1, MAX_BLOCKS)
          context.programs.order(Sequel.desc(:start_date), Sequel.desc(:id)).limit(limit).all
        end

        # The movements worth a row: everything prescribed in the blocks being reported, plus
        # anything carrying a goal. The second half matters -- a lifter who sets a target on
        # an accessory they are bringing up, before it is in any block, would otherwise get
        # silence from the tool they set it for.
        def self.subjects(context, blocks, arguments)
          return [one(context, arguments[:exercise])] if arguments[:exercise]

          ids = prescribed(context, blocks) | Goal.all_for(context.account_id).keys
          context.exercises.where(id: ids).order(:name).all
        end

        # Reached through the block chain rather than by an account column, because only
        # `programs` carries one: a lift is the account's because its day is, because its
        # week is, because its block is.
        def self.prescribed(context, blocks)
          days = context.program_days.where(program_week_id:
            context.program_weeks.where(program_id: blocks.map(&:id)).select(:id))
          context.program_lifts.where(program_day_id: days.select(:id)).distinct.select_map(:exercise_id)
        end

        # Through Resolver.existing_exercise since #454, on the same argument exercise_history
        # makes: this reports a movement's training maxes and block openers, and reading those
        # off an empty library row rather than the lifter's own is a confident wrong answer
        # about whether a block moved anything.
        def self.one(context, name)
          Resolver.existing_exercise(context, name)
        end

        # One movement: what it is worked out from today, what it is aiming at, and what each
        # block opened it at.
        def self.movement(context, exercise, blocks)
          now = TrainingMax.for(account_id: context.account_id, exercise:)
          goal = Goal.for(account_id: context.account_id, exercise_id: exercise.id)
          { exercise: exercise.name, exercise_id: exercise.id,
            training_max: max_view(now), goal: goal_view(goal, now),
            opened_at: blocks.map { |block| opener(context, exercise, block) } }
        end

        # What this block was generated against, read the way the generator read it: the max
        # as of the block's start date, which is the denominator #291 fixed there.
        #
        # `as_of` rather than `for`, which is the whole of why the statement log exists. `for`
        # answers "what is this max" and has no history to consult on the stated branch, so a
        # lifter who has since restated 315 as 325 would be told every block they have ever
        # run opened at 325.
        def self.opener(context, exercise, block)
          was = TrainingMax.as_of(account_id: context.account_id, exercise:, on: block.start_date)
          named(block).merge(max_view(was))
        end

        def self.named(block)
          { program_id: block.id, name: block.name, block: block.block,
            start_date: block.start_date.strftime('%Y-%m-%d') }
        end

        # Nils rather than an absent key, so every row has the same shape and a reader can
        # tell "nothing to say" from "field I forgot to look at".
        def self.max_view(max)
          return { pounds: nil, source: nil, as_of: nil } unless max

          { pounds: max.pounds, source: max.source.to_s, as_of: max.on_date&.strftime('%Y-%m-%d') }
        end

        # The target and the two distances to it, in pounds and in days. Both signed, because
        # a goal passed and a deadline gone by are facts a reader needs rather than numbers to
        # clamp at zero.
        def self.goal_view(goal, now)
          return nil unless goal

          { pounds: goal.pounds, by_date: goal.by_date&.strftime('%Y-%m-%d'),
            remaining_pounds: now && goal.remaining_from(now.pounds), days_remaining: goal.days_from }
        end

        # The prose, because many clients render only the text -- #262's lesson, and this tool
        # would be the easiest of all to reduce to a number nobody can act on.
        def self.summary(rows, blocks)
          return 'No blocks yet, so there is nothing to compare.' if blocks.empty?
          # Blocks with nothing carrying a max or a goal anywhere in them. Said rather than
          # answered with a bare heading and no rows under it, which reads as a tool that
          # failed rather than one with nothing to report.
          if rows.empty?
            return "Across #{blocks.length} block(s), no movement carries a training max or a " \
                   'goal yet, so there is nothing to compare. Set a max on the movements you ' \
                   'are tracking and this answers "am I on pace".'
          end

          ["Across #{blocks.length} block(s), newest first:", *rows.map { |row| line(row) }].join("\n")
        end

        def self.line(row)
          opened = row[:opened_at].map { |block| block[:pounds]&.to_s || '?' }.join(' <- ')
          "  #{row[:exercise]}: opened at #{opened}#{aim(row)}"
        end

        # The goal clause, or nothing at all for a movement with none -- a tool that appended
        # "no goal set" to every row would bury the rows that have one.
        def self.aim(row)
          goal = row[:goal]
          return '' unless goal

          gap = goal[:remaining_pounds]
          days = goal[:days_remaining] ? ", #{goal[:days_remaining]} day(s) away" : ''
          "; aiming at #{goal[:pounds]}#{" (#{gap} lb to go)" if gap}#{days}"
        end
      end
    end
  end
end

