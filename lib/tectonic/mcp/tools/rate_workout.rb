# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Records how hard a whole session was, which is the rating the app already collects
      # at the bottom of the session screen. Per-set ratings go on the sets themselves,
      # through complete_set or update_set; this one is the answer to "how was that
      # session", and the two are different questions about the same training.
      class RateWorkout < Tool
        tool_name 'rate_workout'
        description 'Record how hard a session was, 1 to 10, on the workout for a date ' \
                    "('today' by default) or a workout_id. Rate individual sets with " \
                    'complete_set instead.'
        scope :write
        input_schema(
          type: 'object',
          properties: { rpe: { type: 'integer' }, date: { type: 'string' },
                        workout_id: { type: 'integer' } },
          required: ['rpe'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          Bounds.check(Bounds::RPE, arguments[:rpe], 'RPE')
          workout = find(context, arguments)
          changed = Changes.apply(workout, rpe: arguments[:rpe])
          ok("Session on #{workout.date.strftime('%Y-%m-%d')}: #{Changes.describe(changed)}.",
             structured: Presenter.view_workout(workout.refresh).merge(rpe: workout.rpe, changed:))
        end

        # A rating is about a session that happened, so this never opens one: rating a day
        # that was not trained is a mistake worth being told about rather than a new empty
        # workout carrying a number.
        def self.find(context, arguments)
          return by_id(context, arguments[:workout_id]) if arguments[:workout_id]

          date = Resolver.parse_date(arguments[:date])
          Resolver.find_workout(context, date:) ||
            (raise Tool::Refusal, "No workout on #{date.strftime('%Y-%m-%d')} to rate.")
        end

        def self.by_id(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end
      end
    end
  end
end

