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
                    'YYYY-MM-DD) or a workout_id, which list_workouts and search return.'
        scope :read
        input_schema(
          type: 'object',
          properties: { date: { type: 'string' }, workout_id: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find(context, arguments)
          detail = Presenter.view_workout_detail(workout)
          ok([headline(detail), *detail[:sets].map { |set| line(set) }].join("\n"), structured: detail)
        end

        # The sets have always been in structuredContent, and a client that reads it needs
        # none of this. But plenty of clients surface only the text, and this tool answered
        # "how did Monday go" with a count -- promising the sets in its own description and
        # then printing a summary, which reads as the tool being broken rather than as the
        # client showing one field of the two it was sent.
        # "finished" is said in the prose and not only in the structured payload, because
        # many clients render only the text -- and this is the sentence that was misread.
        # A session sitting at "3 completed, performed" reads as one still under way, which
        # is the whole of #218; the word is what closes it.
        def self.headline(detail)
          "#{detail[:date]}: #{detail[:sets].count} set(s), #{done(detail)} completed, " \
            "#{detail[:status]}#{', finished' if detail[:finished]}."
        end

        # One set: what was on the bar, what was asked for when that differs, and how it
        # went. A warmup says so, because a ramp counted as working sets inflates the
        # volume of every session read off this.
        def self.line(set)
          parts = ["  #{set[:exercise]} #{set[:weight]}x#{set[:reps]}"]
          parts << "(planned #{set[:planned_weight]}x#{set[:planned_reps]})" if revised?(set)
          parts << 'warmup' if set[:is_warmup]
          parts << (set[:is_completed] ? 'done' : 'not done')
          parts << "RPE #{set[:rpe]}" if set[:rpe]
          parts.join(' ')
        end

        # Only worth printing where the prescription and the performance disagree; on a
        # session lifted as written it is the same two numbers twice.
        def self.revised?(set)
          return false unless set[:planned_weight] || set[:planned_reps]

          set[:planned_weight] != set[:weight] || set[:planned_reps] != set[:reps]
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

