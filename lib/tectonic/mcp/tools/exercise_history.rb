# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative '../../one_rep_max'
require_relative '../../training_max'
require_relative '../../timing'

class Tectonic < Roda
  module MCP
    module Tools
      # What has actually been lifted on one movement, over a window, with the estimated
      # max it supports. Answering "is the squat going up" by walking every workout and
      # filtering it client-side costs a call per session and a context window; this is
      # one call, and it is the shape every progression question starts from.
      class ExerciseHistory < Tool
        DEFAULT_LIMIT = 50
        MAX_LIMIT = 200

        tool_name 'exercise_history'

        title 'History of a movement'
        description "The account's own sets of one movement (by name), newest first, with " \
                    'the dates they were lifted and the estimated one-rep max they support. ' \
                    'Narrow with from/to (YYYY-MM-DD). Completed sets only by default, which ' \
                    'is what training history means; pass include_planned for written but ' \
                    'unlifted sets too. Also reports how long this lifter typically takes ' \
                    'between sets of this movement, measured from their own sessions, which ' \
                    'is what to price a prescribed day with.'
        scope :read
        input_schema(
          type: 'object',
          properties: { exercise: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
                        limit: { type: 'integer' }, include_planned: { type: 'boolean' } },
          required: ['exercise'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          exercise = find(context, arguments[:exercise])
          rows = history(context, exercise, arguments).all
          ok(summary(exercise, rows, context, arguments), structured: payload(context, exercise, rows, arguments))
        end

        # The movement by name among the ones this account can see, without creating it:
        # a history question about a movement that has never been logged is answered
        # "nothing", and inventing the movement to say so would leave a row behind.
        def self.find(context, name)
          context.exercises.where(name: name.to_s.strip).order(:id).first ||
            (raise Tool::Refusal, "No exercise named #{name.to_s.strip.inspect} for this account.")
        end

        def self.history(context, exercise, arguments)
          rows = context.sets.where(exercise_id: exercise.id).order(Sequel.desc(:id))
          rows = rows.where(is_completed: true) unless arguments[:include_planned]
          window(context, rows, arguments).limit(limit_for(arguments))
        end

        # Dates live on the workout, not the set, so a window is a filter on the sessions
        # the sets belong to -- still inside the account-scoped dataset, which is what
        # keeps another account's lifting unreachable from here.
        def self.window(context, rows, arguments)
          workouts = context.workouts
          workouts = workouts.where { date >= Resolver.parse_date(arguments[:from]) } if arguments[:from]
          workouts = workouts.where { date < (Resolver.parse_date(arguments[:to]) + 1) } if arguments[:to]
          rows.where(workout_id: workouts.select(:id))
        end

        def self.limit_for(arguments)
          (arguments[:limit] || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        end

        # estimated_1rm keeps its name and its meaning: the max the chart reads out of the
        # sets, which is what it has always been. training_max beside it is what a
        # percentage actually resolves against, which since #264 is the stated one where
        # there is one -- so the two disagree exactly when somebody has overridden the
        # estimate, and an assistant reading this can tell that they have.
        #
        # Reporting only the resolved number would have been smaller and wrong. "Your max
        # is 315" and "you told us your max is 315" are different claims, and an assistant
        # advising on a block needs the second: a stated max is a standing instruction, and
        # a derived one is a reading that a layoff quietly invalidates.
        #
        # typical_turnaround_seconds is #263's, and it answers a different question about
        # the same movement: not how heavy, but how long. It is what lets an assistant price
        # a prescribed day -- five squat sets is roughly five of these -- in the lifter's own
        # numbers instead of in a constant somebody chose. Off the rows already fetched, so
        # it costs no query, and nil where nothing can be measured: a movement lifted once,
        # and every movement whose sets predate #281. A zero would read as instantaneous.
        def self.payload(context, exercise, rows, arguments)
          { exercise: exercise.name, exercise_id: exercise.id, shown: rows.length,
            limit: limit_for(arguments), estimated_1rm: estimated(context, exercise, arguments),
            typical_turnaround_seconds: turnaround(rows),
            sets: rows.map { |set| Presenter.view_set(set).merge(date: set.workout.date.strftime('%Y-%m-%d')) } }
            .merge(max_fields(context, exercise, arguments))
        end

        # The resolved max as three keys: the number, which of the two kinds it is, and the
        # day it is as of. Split out because they are one fact in three parts and because a
        # payload naming every field of every fact in one literal is a method doing several
        # jobs -- which rubocop counted before a reader would have.
        def self.max_fields(context, exercise, arguments)
          resolved = resolved_max(context, exercise, arguments)
          { training_max: resolved&.pounds, training_max_source: resolved&.source,
            training_max_as_of: resolved&.on_date&.strftime('%Y-%m-%d') }
        end

        # Grouped by session inside Timing, so two sets a week apart are never subtracted
        # from one another. The rows carry workout_id already.
        def self.turnaround(rows)
          Timing.between_sets_of(rows.map(&:values))
        end

        # The max as of the end of the window rather than as of today, so asking about a
        # block that finished in March is answered with what was true in March. Without a
        # window it means now, which is what "what can I lift" asks.
        def self.estimated(context, exercise, arguments)
          exercise.estimated_max(account_id: context.account_id, on: as_of(arguments))
        end

        # What a percentage lift would generate against: the stated max if there is one and
        # the derived reading otherwise. Through TrainingMax rather than repeating the
        # fallback, so this and ProgramGenerator cannot come to different conclusions about
        # the same movement -- which would make this tool describe a block it is not
        # generating.
        def self.resolved_max(context, exercise, arguments)
          TrainingMax.for(account_id: context.account_id, exercise:, on: as_of(arguments))
        end

        def self.as_of(arguments)
          arguments[:to] ? Resolver.parse_date(arguments[:to]) : Date.today
        end

        # `compact` before `max`, which is a second bug found while fixing the first. The
        # column is nullable and unweighted work stores nothing in it, so a movement with
        # both weighted and bodyweight sets in its history -- a pull-up, say -- reached
        # `max` with a nil among BigDecimals and raised ArgumentError rather than answering.
        # A history question about a mixed movement failed outright.
        #
        # The prose says the resolved max rather than the estimate, because it is the number
        # the next block will be built on, and it says which kind it is -- many clients show
        # only this text, and "max 315" that turns out to be a guess off a set from before a
        # layoff is the misreading #264 is about.
        def self.summary(exercise, rows, context, arguments)
          heaviest = Presenter.weight(rows.map(&:weight).compact.max)
          "#{exercise.name}: #{rows.length} set(s), heaviest #{heaviest || 'none'}, " \
            "#{max_phrase(resolved_max(context, exercise, arguments))}#{pace(rows)}."
        end

        def self.max_phrase(resolved)
          return 'no training max yet and nothing lifted to estimate one from' unless resolved

          dated = resolved.on_date ? ", from #{resolved.on_date.strftime('%-d %b %Y')}" : ''
          "training max #{Presenter.weight(resolved.pounds)} (#{resolved.explanation}#{dated})"
        end

        # How long a set of this costs, in the sentence as well as the payload -- many
        # clients render only the text, which is #262's lesson. Silent where there is nothing
        # measured, rather than printing a zero that reads as instantaneous.
        def self.pace(rows)
          seconds = turnaround(rows)
          seconds && ", about #{Timing.phrase(seconds)} between sets of it"
        end
      end
    end
  end
end

