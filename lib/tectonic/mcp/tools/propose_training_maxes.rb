# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../one_rep_max'
require_relative '../../training_max'

class Tectonic < Roda
  module MCP
    module Tools
      # What recent training says the next block should open at. #449.
      #
      # The pieces have been here separately for a long time: sets carry RPE, `set_training_max`
      # writes the reference, `exercise_history` reads completed work, and `OneRepMax` turns a
      # rated set into a number. Nothing put them in a line. So the loop a lifter actually runs
      # -- train a block, see what it cost, price the next one -- was four calls and a
      # calculation done by hand, every time.
      #
      # ## It proposes and does not write
      #
      # #449 asks for exactly that, and it is also the only shape this tool could honestly
      # take. Which number a block opens at is a coaching decision: a peaking block and a
      # hypertrophy block want different fractions of the same demonstrated max, and a lifter
      # coming off a layoff wants neither. #263 settled that split, and #308's refusal to
      # compute "behind schedule" is the same refusal.
      #
      # So this returns the arithmetic and the set it came from, and the assistant argues with
      # the lifter about what to do with it. `set_training_max` is one call away and is where
      # a decision gets written.
      #
      # ## Only readings that could stand on their own
      #
      # Through `Exercise#window_of`, which reads the window with `best_confident_reading` and
      # so holds `CONFIDENT_REPS` -- the same bar `TrainingMax.derived` already clears before a
      # reading is allowed to become a denominator. A proposal drawn from a set nine reps from
      # a single would be the app suggesting a block be priced off a reading it declines to
      # trust itself.
      #
      # That is why some movements come back with no proposal and a reason rather than being
      # dropped. "Trained nine times, nothing near enough to a single to read" is a useful
      # answer -- it tells a lifter their accessory work cannot price anything, which is true
      # and is not a failure of the tool.
      #
      # ## A window, not a lifetime
      #
      # A training max is what the next block is generated against, and what has ever been
      # demonstrated is the wrong input for that -- #307 makes the argument at length: there is
      # no lower bound on a lifetime best, so a single from three years ago outranks everything
      # since and nothing about the number says so.
      #
      # Eight weeks by default, which is about one block. The lifetime reading is still there
      # in `exercise_history` and this does not replace it; it answers the other question.
      class ProposeTrainingMaxes < Tool
        DEFAULT_WEEKS = 8
        MAX_WEEKS = 52

        tool_name 'propose_training_maxes'
        title 'Propose training maxes'
        description 'What recent training implies the next block should be priced off, ' \
                    'movement by movement. For each one it returns the training max in ' \
                    'force now, the best estimate from completed rated sets in the window, ' \
                    'the set that estimate came from, and the difference. Narrow to one ' \
                    'movement with exercise, and change the window with weeks (8 by ' \
                    'default, about one block). It proposes and writes nothing: which ' \
                    'number a block opens at depends on what kind of block it is, and that ' \
                    'is a coaching decision rather than arithmetic. Use set_training_max to ' \
                    'act on it. Readings further than six reps from a single are not ' \
                    'proposed from, which is the same bar the app holds before letting an ' \
                    'estimate become a training max on its own.'
        scope :read
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, weeks: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          weeks = (arguments[:weeks] || DEFAULT_WEEKS).clamp(1, MAX_WEEKS)
          rows = subjects(context, arguments).map { |exercise| movement(context, exercise, weeks) }
                                             .reject { |row| row[:trained_sets].zero? }
          ok(summary(rows, weeks), structured: { weeks:, movements: rows })
        end

        # The movements worth reading: everything this account has completed a working set of
        # inside the window, or the one that was named.
        #
        # Scoped through the account's own workouts rather than by exercise alone, because a
        # library movement is shared and the training on it is not.
        def self.subjects(context, arguments)
          return [Resolver.exercise(context, name: arguments[:exercise])] if arguments[:exercise]

          Exercise.where(id: context.sets.where(is_completed: true, is_warmup: false)
                                    .select(:exercise_id)).order(:name).all
        end

        # One movement's row: what it is priced off now, what the window supports, and the gap.
        #
        # The count and the reading come from one read of the window, which is `window_of`'s
        # whole reason: taken separately they could report a movement trained nine times with
        # nothing readable in it, having looked at two different nine.
        def self.movement(context, exercise, weeks)
          window = exercise.window_of(account_id: context.account_id, weeks:, on: context.today)
          current = TrainingMax.for(account_id: context.account_id, exercise:, on: context.today)
          { exercise: exercise.name, exercise_id: exercise.id, trained_sets: window[:sets] }
            .merge(standing(current)).merge(proposal(window[:reading], current))
        end

        # What the movement is priced off today, and where that number came from. The source
        # matters to a reader: a stated max is somebody's decision and a derived one is the
        # app's arithmetic, and a proposal argues with them differently.
        def self.standing(current)
          return { current: nil, current_source: nil } unless current

          { current: Plates.numeric(current.pounds), current_source: current.source.to_s }
        end

        # The proposal, or the reason there is not one. Never both, and never silence.
        def self.proposal(reading, current)
          return { proposed: nil, why_not: 'no set in this window is close enough to a single to read' } unless reading

          standing = current && Plates.numeric(current.pounds)
          { proposed: reading[:pounds], from: from_phrase(reading), on: reading[:on].to_s,
            change: standing && (reading[:pounds] - standing) }
        end

        # The set the number came from, said as the set rather than as a conclusion. This is
        # the "showing its arithmetic" half of the issue: a proposal of 127 means nothing on
        # its own, and "100 x 5 at RPE 7, which is 6 reps from a single, so 78.6%" can be
        # argued with.
        def self.from_phrase(reading)
          "#{Plates.numeric(reading[:weight])} lb x #{reading[:reps]} at RPE #{reading[:rating]}, " \
            "which is #{reading[:from_reps]} #{reading[:from_reps] == 1 ? 'rep' : 'reps'} from a single"
        end

        def self.summary(rows, weeks)
          moved = rows.select { |row| row[:change] && !row[:change].zero? }
          return "Nothing in the last #{weeks} weeks reads differently from what you train off." if moved.empty?

          "#{moved.length} of #{rows.length} movements read differently from the number they are " \
            "priced off: #{moved.map { |row| phrase(row) }.join('; ')}. Nothing is written."
        end

        def self.phrase(row)
          "#{row[:exercise]} #{row[:current]} to #{row[:proposed]} (#{row[:from]})"
        end
      end
    end
  end
end

