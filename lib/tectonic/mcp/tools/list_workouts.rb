# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
require_relative '../../timing'

class Tectonic < Roda
  module MCP
    module Tools
      # Lists the account's workouts, most recent first, never another account's.
      #
      # Bounded, which it was not: it returned every workout the account had ever had, so
      # the one usable history call grew by a row a session forever and would eventually
      # not fit in the window it was being read into. It now takes a date range and a
      # limit, defaults to the recent past, and says how many rows it held back rather
      # than letting a model believe it has seen everything there is.
      class ListWorkouts < Tool
        DEFAULT_LIMIT = 20
        MAX_LIMIT = 200

        tool_name 'list_workouts'
        description "List the account's workouts, most recent first, with set counts, " \
                    'whether each is planned, performed or skipped, and how long each one ' \
                    'took. Narrow with from/to (YYYY-MM-DD) and limit; the default is the ' \
                    "#{DEFAULT_LIMIT} most recent."
        scope :read
        input_schema(
          type: 'object',
          properties: { from: { type: 'string' }, to: { type: 'string' }, limit: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          matching = window(context, arguments)
          total = matching.count
          # eager(:sets) because every row below reads them: Presenter.view_workout counts
          # them and the timing subtracts their stamps. Without it that is a query a workout
          # -- twenty for a default page -- which is #234's shape in the one list that had
          # escaped it. Two queries now, however long the page.
          workouts = matching.with_performance.order(Sequel.desc(:date), Sequel.desc(:id))
                             .limit(limit_for(arguments)).eager(:sets).all
          ok(summary(workouts, total), structured: payload(workouts, total, arguments))
        end

        def self.window(context, arguments)
          workouts = context.workouts
          workouts = workouts.where { date >= Resolver.parse_date(arguments[:from]) } if arguments[:from]
          workouts = workouts.where { date < (Resolver.parse_date(arguments[:to]) + 1) } if arguments[:to]
          workouts
        end

        def self.limit_for(arguments)
          (arguments[:limit] || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
        end

        # How long each one took rides along with the counts (#263). A question about pace
        # over a month -- "are my sessions getting longer" -- was otherwise a call per
        # session, and the numbers are already in the rows this loads.
        # `active_seconds` and the gap count ride along since #318, because a month of
        # sessions is exactly where a 24-hour figure does the most damage: one session
        # spanning midnight makes "are my sessions getting longer" unanswerable, and nothing
        # in this payload said which row to distrust.
        def self.timing_of(workout)
          measured = Timing.session(workout, workout.sets.map(&:values))
          { seconds: measured[:overall], active_seconds: measured[:active],
            long_gaps: measured[:discarded], typical_turnaround_seconds: measured[:typical_turnaround] }
        end

        def self.payload(workouts, total, arguments)
          rows = workouts.map { |w| Presenter.view_workout(w).merge(status: w.status.to_s, timing: timing_of(w)) }
          { workouts: rows,
            shown: workouts.length, total:, withheld: total - workouts.length, limit: limit_for(arguments) }
        end

        # The withheld count is the point of the first line: a model told "20 workouts" and
        # not told there are 63 will answer a question about the year from a fortnight.
        #
        # The rows below it are #262. The description promises set counts and a status per
        # workout; the text was a single sentence carrying a total and nothing else, so a
        # client rendering only the text -- which many are -- got a number where it had been
        # told to expect a list, and no id to follow up with.
        def self.summary(workouts, total)
          [count_line(workouts, total), *workouts.map { |workout| row(workout) }].join("\n")
        end

        def self.count_line(workouts, total)
          return "You have #{total} workout(s) in this range." if workouts.length == total

          "Showing #{workouts.length} of #{total} workout(s), most recent first; " \
            "#{total - workouts.length} not shown. Narrow with from/to or raise limit."
        end

        # One workout: when, what it is called, how much of it is done, and where it sits
        # in the plan. `label` rather than `name` because a generated session has no name
        # of its own and is known by its program day's focus.
        def self.row(workout)
          view = Presenter.view_workout(workout)
          done = "#{view[:completed]} of #{view[:sets]} set(s) done"
          "  [workout #{view[:id]}] #{view[:date]}#{" #{view[:label]}" if view[:label]}: " \
            "#{done}, #{workout.status}#{', finished' if view[:finished]}#{took(workout)}"
        end

        # Silent on a session with no stamps, which is every one trained before #281. A "0m"
        # in a list of twenty would read as a real session that took no time.
        #
        # A row is one line in a list, so the pair is spelled tightly -- "9m active of 24h" --
        # rather than in get_workout's full sentence. It appears only where the two numbers
        # differ, which keeps nineteen ordinary rows reading as they did.
        def self.took(workout)
          measured = timing_of(workout)
          return nil unless measured[:seconds]
          return ", #{Timing.phrase(measured[:seconds])}" unless measured[:long_gaps].positive?

          ", #{Timing.phrase(measured[:active_seconds])} active of #{Timing.phrase(measured[:seconds])}"
        end
      end
    end
  end
end

