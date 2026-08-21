# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # One session, in full: every set in the order it is meant to be lifted, what was
      # prescribed beside what was actually done, whether each set was completed, and how
      # the session was rated.
      #
      # This is the call behind "how did Monday go". Reading it off list_workouts was
      # never possible -- that returns a count -- and reading it off fetch meant parsing a
      # prose sentence that had already thrown away the warmup flags and the prescription.
      class GetWorkout < Tool
        tool_name 'get_workout'
        description 'Read one session in full: its sets in order with weight, reps, RPE, ' \
                    'whether each was a warmup and whether it was completed, what the ' \
                    "program prescribed, and the session rating. Give a date ('today' or " \
                    'YYYY-MM-DD) or a workout_id.'
        scope :read
        input_schema(
          type: 'object',
          properties: { date: { type: 'string' }, workout_id: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find(context, arguments)
          detail = Presenter.view_workout_detail(workout)
          ok("#{detail[:date]}: #{detail[:sets].count} set(s), #{done(detail)} completed, " \
             "#{detail[:status]}.", structured: detail)
        end

        # By id when given one, otherwise by date, which defaults to today. A day that was
        # never trained is a refusal rather than an empty session: nothing was there, and
        # saying so is more useful than a workout-shaped hole.
        def self.find(context, arguments)
          return by_id(context, arguments[:workout_id]) if arguments[:workout_id]

          date = Resolver.parse_date(arguments[:date])
          Resolver.find_workout(context, date:) ||
            (raise Tool::Refusal, "No workout on #{date.strftime('%Y-%m-%d')} for this account.")
        end

        def self.by_id(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end

        def self.done(detail)
          detail[:sets].count { |set| set[:is_completed] }
        end
      end
    end
  end
end

