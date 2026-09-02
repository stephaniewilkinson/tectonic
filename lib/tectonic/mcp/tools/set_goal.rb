# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../goal'
require_relative '../../training_max'

class Tectonic < Roda
  module MCP
    module Tools
      # States what a movement is aiming at, and when by. #308.
      #
      # A tool of its own for `set_training_max`'s reason, and it is the same reason twice: a
      # goal is keyed on the account and the movement, so it is private by construction and
      # works on a shared library movement -- which is where it is most wanted, since the
      # Back Squat everybody trains is a library row. Folding it into `update_exercise`, which
      # refuses a library movement by name and is right to, would mean loosening that rule for
      # one field or refusing the case this exists for.
      #
      # Distinct from `set_training_max`, and the two are easy to confuse: the training max is
      # what percentages are taken of *now*, and this is a number nobody is lifting yet.
      # Writing a goal into the training max would generate an entire block off a weight the
      # lifter cannot handle, which is the failure worth being loud about in the description.
      class SetGoal < Tool
        tool_name 'set_goal'
        description 'Set what a movement (by name) is aiming at, in pounds, and optionally ' \
                    'a date to reach it by (YYYY-MM-DD). This is a target, NOT the number ' \
                    'percentages are taken of -- use set_training_max for that. A goal is ' \
                    'read back by block_progress beside what each block actually opened at, ' \
                    'which is what makes "am I on pace" answerable. Omit pounds, or send 0, ' \
                    'to drop the goal. The date is optional: a target with no deadline is ' \
                    'still a target. Works on shared library movements; the goal belongs to ' \
                    'this account, not to the movement.'
        scope :write
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, pounds: { type: 'number' },
                        by_date: { type: 'string' } },
          required: ['exercise'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = Resolver.exercise(context, name: arguments[:exercise])
          Bounds.check(Bounds::WEIGHT, arguments[:pounds], 'Goal', unit: ' lb')
          Goal.replace(context.account_id, exercise.id, arguments[:pounds],
                       by_date: parsed(arguments[:by_date]))
          answer(context, exercise)
        end

        # Through the same Resolver every other tool parses a date with, so 'today' and an
        # ISO day mean here what they mean everywhere, and an unreadable one is refused in one
        # voice rather than silently dropped. `Goal.parse_date` is more forgiving because the
        # browser form is, and a form posting a malformed date should still save the number
        # somebody came to type; a tool call is a machine talking and can be told.
        def self.parsed(raw)
          raw && Resolver.parse_date(raw)
        end

        # What the movement now aims at, read back rather than echoed, and beside what it is
        # worked out from today -- because the gap between those two is the only reason to set
        # a goal, and an assistant told only "saved" would have to make a second call to say
        # anything useful about it.
        def self.answer(context, exercise)
          goal = Goal.for(account_id: context.account_id, exercise_id: exercise.id)
          now = TrainingMax.for(account_id: context.account_id, exercise:)
          ok(sentence(exercise, goal, now),
             structured: { exercise: exercise.name, exercise_id: exercise.id,
                           goal: goal&.pounds, by_date: goal&.by_date&.strftime('%Y-%m-%d'),
                           training_max: now&.pounds,
                           remaining_pounds: now && goal&.remaining_from(now.pounds),
                           days_remaining: goal&.days_from })
        end

        # The unit is said out loud on every number here, which is #280's rule: a bare pair
        # of weights in one sentence is exactly where "405" and "95" stop being obviously the
        # same kind of quantity.
        def self.sentence(exercise, goal, now)
          return "#{exercise.name}: goal dropped." unless goal

          "#{exercise.name}: aiming at #{Presenter.weight(goal.pounds)} lb" \
            "#{goal.deadline_phrase}.#{standing(goal, now)}"
        end

        # Where it stands today, or nothing at all when there is no max to stand against --
        # a movement never lifted and never stated has no starting point, and inventing one
        # to fill the sentence would be the app making up the number the goal is measured
        # from.
        def self.standing(goal, now)
          return '' unless now

          " Percentages are worked out from #{Presenter.weight(now.pounds)} lb today" \
            "#{gap(goal, now)}."
        end

        def self.gap(goal, now)
          remaining = goal.remaining_from(now.pounds)
          return '' if remaining.nil? || remaining.zero?
          return ", which is #{Presenter.weight(-remaining)} lb past the goal" if remaining.negative?

          ", so #{Presenter.weight(remaining)} lb to go"
        end
      end
    end
  end
end

