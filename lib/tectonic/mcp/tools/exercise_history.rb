# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative '../../one_rep_max'

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
        description "The account's own sets of one movement (by name), newest first, with " \
                    'the dates they were lifted and the estimated one-rep max they support. ' \
                    'Narrow with from/to (YYYY-MM-DD). Completed sets only by default, which ' \
                    'is what training history means; pass include_planned for written but ' \
                    'unlifted sets too.'
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

        def self.payload(context, exercise, rows, arguments)
          { exercise: exercise.name, exercise_id: exercise.id, shown: rows.length,
            limit: limit_for(arguments), estimated_1rm: estimated(context, exercise, arguments),
            sets: rows.map { |set| Presenter.view_set(set).merge(date: set.workout.date.strftime('%Y-%m-%d')) } }
        end

        # The max as of the end of the window rather than as of today, so asking about a
        # block that finished in March is answered with what was true in March. Without a
        # window it means now, which is what "what can I lift" asks.
        def self.estimated(context, exercise, arguments)
          on = arguments[:to] ? Resolver.parse_date(arguments[:to]) : Date.today
          exercise.estimated_max(account_id: context.account_id, on:)
        end

        # `compact` before `max`, which is a second bug found while fixing the first. The
        # column is nullable and unweighted work stores nothing in it, so a movement with
        # both weighted and bodyweight sets in its history -- a pull-up, say -- reached
        # `max` with a nil among BigDecimals and raised ArgumentError rather than answering.
        # A history question about a mixed movement failed outright.
        def self.summary(exercise, rows, context, arguments)
          heaviest = Presenter.weight(rows.map(&:weight).compact.max)
          "#{exercise.name}: #{rows.length} set(s), heaviest #{heaviest || 'none'}, " \
            "estimated max #{estimated(context, exercise, arguments) || 'not yet readable'}."
        end
      end
    end
  end
end

