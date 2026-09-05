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
                    'movement with exercise, and how far back with blocks. It reports the ' \
                    'numbers and does not judge whether they are enough.'
        scope :read
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, blocks: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          blocks = recent(context, arguments)
          movements = subjects(context, blocks, arguments)
          rows = movements.map { |exercise| movement(context, exercise, blocks) }
          ok(summary(rows, blocks), structured: { movements: rows, blocks: blocks.map { |b| named(b) } })
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

        def self.one(context, name)
          context.exercises.where(name: name.to_s.strip).order(:id).first ||
            (raise Tool::Refusal, "No exercise named #{name.to_s.strip.inspect} for this account.")
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

