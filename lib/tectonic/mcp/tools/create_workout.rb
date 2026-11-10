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
        title 'Start a session'
        description "Open the account's workout for a date (today or YYYY-MM-DD), reusing one " \
                    'already on that day. Optional name (which session, on a day with two) and ' \
                    'note (how it went). On a reused workout, a name or note given replaces the ' \
                    'one there and an empty string clears it; omitted leaves it alone.'
        scope :write
        input_schema(
          type: 'object',
          properties: { date: { type: 'string' }, name: { type: 'string' },
                        note: { type: 'string' } },
          required: ['date'], additionalProperties: false
        )

        # The name is applied whether the workout was opened or found, because this tool is
        # idempotent on the day and the second call is the one that usually carries it: an
        # assistant opens today's session, logs a set, and only then is told it was the
        # evening walk. Absent, the name is left exactly as it was rather than cleared --
        # `key?` rather than a nil check, so "do not touch it" and "empty it" stay
        # different requests, the second spelled as an empty string.
        def self.perform(context:, arguments:)
          workout = Resolver.workout(context, date: Resolver.parse_date(arguments[:date]))
          workout.update(name: Workout.clean_name(arguments[:name])) if arguments.key?(:name)
          # And how it went, on exactly the same terms (#310): absent leaves it, an empty
          # string clears it. Here rather than in a tool of its own because a note is a fact
          # about the session and this is the tool that opens one -- and because it arrives
          # the same way a name does, after the fact, once there is something to say.
          workout.update(note: Workout.clean_note(arguments[:note])) if arguments.key?(:note)
          ok("Workout on #{workout.date.strftime('%Y-%m-%d')} is ready (id #{workout.id}).",
             structured: Presenter.view_workout(workout))
        end
      end
    end
  end
end

