# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Opens (or returns) the account's workout for a date. Idempotent on the day,
      # so calling it twice for the same date logs into one workout, not two.
      class CreateWorkout < Tool
        tool_name 'create_workout'
        description "Open the account's workout for a date ('today' or YYYY-MM-DD), " \
                    'reusing an existing one on that day instead of creating a duplicate.'
        scope :write
        input_schema(
          type: 'object',
          properties: { date: { type: 'string' } },
          required: ['date'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = Resolver.workout(context, date: Resolver.parse_date(arguments[:date]))
          ok("Workout on #{workout.date.strftime('%Y-%m-%d')} is ready (id #{workout.id}).",
             structured: Presenter.view_workout(workout))
        end
      end
    end
  end
end

