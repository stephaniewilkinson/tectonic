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
                    'program prescribed, the session rating, and how long it took. Give a ' \
                    "date ('today' or YYYY-MM-DD) or a workout_id, which list_workouts and " \
                    'search return.'
        scope :read
        input_schema(
          type: 'object',
          properties: { date: { type: 'string' }, workout_id: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find(context, arguments)
          detail = Presenter.view_workout_detail(workout)
          ok([headline(detail), *note_line(detail), *detail[:sets].map { |set| line(set) }].join("\n"),
             structured: detail)
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
            "#{detail[:status]}#{', finished' if detail[:finished]}#{timing(detail)}."
        end

        # What the lifter said about the day, above the sets rather than after them (#310).
        # It is the thing that explains them: an RPE of 9 and a fourteen minute turnaround
        # both read differently once "slept badly" is on the page, and an assistant reading
        # the sets first would have already drawn its conclusion by the time it got there.
        #
        # An array so the caller can splat it -- a session with no note contributes no line
        # rather than a blank one.
        def self.note_line(detail)
          detail[:note] ? ["  note: #{detail[:note]}"] : []
        end

        # How long it ran and what a normal turnaround was, in the sentence rather than only
        # in the structured payload -- many clients render only the text, which is #262's
        # lesson and the reason this tool prints its sets at all.
        #
        # "Turnaround" and never "rest". One tap per set measures the gap between two taps,
        # which is the rest plus the working time of the set that ended it; naming it rest
        # would tell an assistant the app knows something it does not. See
        # lib/tectonic/timing.rb.
        #
        # Silent on a session with no stamps, which is every session trained before #281 and
        # every one not yet trained. "0m" would be a claim about training that never
        # happened, and a model reading it would repeat the claim.
        def self.timing(detail)
          measured = detail[:timing]
          return '' unless measured && measured[:overall]

          phrase = ", #{Timing.phrase(measured[:overall])}#{' so far' if measured[:overall_basis] == :in_progress}"
          return phrase unless measured[:typical_turnaround]

          "#{phrase}, typically #{Timing.phrase(measured[:typical_turnaround])} between sets"
        end

        # One set: what was on the bar, what was asked for when that differs, and how it
        # went. A warmup says so, because a ramp counted as working sets inflates the
        # volume of every session read off this.
        def self.line(set)
          parts = ["  #{set[:exercise]} #{quantity(set)}"]
          parts << "(planned #{set[:planned_weight]}x#{set[:planned_reps]})" if revised?(set)
          parts << 'warmup' if set[:is_warmup]
          parts << (set[:is_completed] ? 'done' : 'not done')
          parts << rating(set) if set[:rpe] || set[:planned_rpe]
          parts.join(' ')
        end

        # The effort, as asked for and as answered. #265, and this is the read-back that
        # issue is really for: the app already stores both halves of "what was prescribed
        # versus what happened" for weight and for reps, and printing only the answer threw
        # away the half that makes the other one mean anything.
        #
        # Both numbers only where they differ, on the same rule the planned weight above
        # follows -- on a set taken exactly as asked it is the same figure twice. A target
        # with no answer is a set not yet rated, and says so rather than printing a bare
        # number an assistant would read as the rating.
        def self.rating(set)
          return "RPE #{set[:rpe]}" unless set[:planned_rpe]
          return "RPE target #{set[:planned_rpe]}, not yet rated" unless set[:rpe]
          return "RPE #{set[:rpe]}" if set[:rpe] == set[:planned_rpe]

          "RPE #{set[:rpe]} (target #{set[:planned_rpe]})"
        end

        # What was on the bar and how many times it moved, in the session screen's own words.
        #
        # "per side" is #306, and it is a correction rather than an addition. A split squat
        # written 3x8 per side printed here as `40x8`, so an assistant reading a session back
        # reasoned about volume, fatigue and progression off half the work -- while this app's
        # own Volume figures, which have doubled a per-side count since #279, said sixteen.
        # Two numbers from one app differing by exactly 2x with nothing to say which was
        # which, which is worse than either being wrong alone. `load_label` on the session
        # screen has said it all along; only the read tools were silent.
        def self.quantity(set)
          "#{set[:weight]}x#{set[:reps]}#{' per side' if set[:is_per_side]}"
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

