# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../training_max'

class Tectonic < Roda
  module MCP
    module Tools
      # States the max a movement's percentages are taken of. #264.
      #
      # A tool of its own rather than a field on update_exercise, and the reason is the one
      # #264 turns on. update_exercise is scoped to what the account *owns* and refuses a
      # library movement by name, correctly: a library row sits on every account's page, so
      # a value written to it is one account's answer that everybody else reads. A training
      # max is not like that. It is keyed on the pair, so it is private by construction, and
      # the movement it is most wanted for is usually a library one -- the Back Squat
      # everybody shares. Folding it into update_exercise would mean either loosening that
      # tool's ownership rule for one field, or refusing the case this feature exists for.
      #
      # The counterpart to it is clearing, which is the same call with pounds omitted or
      # zero: that hands the question back to the estimate, which is the only way back.
      class SetTrainingMax < Tool
        tool_name 'set_training_max'
        title 'Set a training max'
        description 'Set the number percentages of one movement (by name) are taken of, ' \
                    'in pounds. Which number that should be depends on the programme and ' \
                    'the app does not guess: a 5/3/1-style block wants roughly 90% of a ' \
                    'one-rep max, while percentage programming in the Sheiko tradition is ' \
                    'written against a competition max directly -- so ask the lifter which ' \
                    'convention they train on rather than sending a tested single by ' \
                    'default. Without a stated max the app falls back to an estimated ' \
                    'one-rep max off completed sets, which is a lifetime best with no lower ' \
                    'bound -- right most of the time, and wrong in the two cases this ' \
                    'exists for: coming off a layoff, where it reads work done before the ' \
                    'break, and a movement never logged, where there is nothing to read. ' \
                    'Omit pounds, or send 0, to clear it and go back to the estimate. Works ' \
                    'on shared library movements too: the value belongs to this account, ' \
                    'not to the movement. train_at_percent, 50 to 100, is the fraction of ' \
                    'that number percentages are actually taken of -- send pounds 500 and ' \
                    'train_at_percent 90 for a 5/3/1 lifter with a tested 500 single, or ' \
                    'leave it out to train off the whole number, which is what a ' \
                    'competition-max convention means.'
        scope :write
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, pounds: { type: 'number' },
                        train_at_percent: { type: 'integer' } },
          required: ['exercise'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = Resolver.exercise(context, name: arguments[:exercise])
          Bounds.check(Bounds::WEIGHT, arguments[:pounds], 'Training max', unit: ' lb')
          Bounds.check(TrainingMax::TRAIN_AT, arguments[:train_at_percent], 'Train at', unit: '%')
          TrainingMax.replace(context.account_id, exercise.id, arguments[:pounds],
                              train_at: arguments.fetch(:train_at_percent, TrainingMax::WHOLE))
          answer(context, exercise)
        end

        # What the movement now resolves against, read back rather than echoed. A cleared
        # max falls through to the estimate, and which of the two the caller ended up with
        # is the thing worth reporting -- an assistant that clears a max and is told
        # "cleared" does not know whether percentages will now generate at all.
        def self.answer(context, exercise)
          resolved = TrainingMax.for(account_id: context.account_id, exercise:)
          ok(sentence(exercise, resolved),
             structured: { exercise: exercise.name, exercise_id: exercise.id,
                           training_max: resolved&.pounds, source: resolved&.source })
        end

        def self.sentence(exercise, resolved)
          return nothing_to_go_on(exercise) unless resolved

          "#{exercise.name}: percentages now resolve against #{Presenter.weight(resolved.pounds)}, " \
            "#{resolved.explanation}."
        end

        def self.nothing_to_go_on(exercise)
          "#{exercise.name}: no training max and nothing lifted to estimate one from, so a lift " \
            'written as a percentage of it cannot be generated yet.'
        end
      end
    end
  end
end

