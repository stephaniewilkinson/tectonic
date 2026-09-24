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

        title 'List sessions'
        description "List the account's workouts, most recent first, with set counts, " \
                    'whether each is planned, performed or skipped, and how long each one ' \
                    'took. Each row carries three dates: performed_or_planned_on is the day ' \
                    'it was trained and is the one the app itself shows; date is the day the ' \
                    'session was written for, and is what from/to match on and what ' \
                    'get_workout takes; performed_on is null until something in it has been ' \
                    'ticked off. They differ whenever a session was trained early or late. ' \
                    'Narrow with from/to (YYYY-MM-DD) and limit; the default is the ' \
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
          #
          # eager(:program_day) is #594 and it is the list-page ticket's bug in a tool:
          # `view_workout` prints `label`, which is `name || program_day&.focus`, so every
          # generated session nobody renamed was a primary-key lookup of its own. Production
          # has 32 of 54 taking that branch.
          #
          # with_performed_on rather than with_performance is #606, and the two halves of that
          # issue are one change. The rows print a date apiece and since #572 the date a
          # session is known by is the day it was trained; this tool printed the stored column,
          # so the app said Wednesday and the connector said Friday about the same session.
          # Reading the right date without asking for it in this query would have cost a query
          # per workout through `performed_on`'s fallback -- the same shape as the eager loads
          # beside it, arriving while it was being removed. with_performed_on is
          # with_performance plus one correlated subquery, so this is the same one query.
          workouts = matching.with_performed_on.order(Sequel.desc(:date), Sequel.desc(:id))
                             .limit(limit_for(arguments)).eager(:sets, :program_day).all
          ok(summary(workouts, total, context.today),
             structured: payload(workouts, total, arguments, context.today))
        end

        def self.window(context, arguments)
          from, to = bounds(context, arguments)
          workouts = context.workouts
          workouts = workouts.where { date >= from } if from
          workouts = workouts.where { date < (to + 1) } if to
          workouts
        end

        # Parsed before the datasets are built, so each bound is read once and so "today"
        # means the lifter's today rather than the server's (#349).
        def self.bounds(context, arguments)
          [arguments[:from] && Resolver.parse_date(arguments[:from], on: context.today),
           arguments[:to] && Resolver.parse_date(arguments[:to], on: context.today)]
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

        # `on` is the lifter's today (#349), threaded from the request context rather than
        # asked for here: a status is :planned or :skipped depending on which side of midnight
        # the reader is on, and on the server's clock a Monday evening session reads as missed.
        def self.payload(workouts, total, arguments, on)
          rows = workouts.map do |w|
            Presenter.view_workout(w).merge(status: w.status(on).to_s, timing: timing_of(w))
          end
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
        def self.summary(workouts, total, on)
          [count_line(workouts, total), *workouts.map { |workout| row(workout, on) }].join("\n")
        end

        def self.count_line(workouts, total)
          return "You have #{total} workout(s) in this range." if workouts.length == total

          "Showing #{workouts.length} of #{total} workout(s), most recent first; " \
            "#{total - workouts.length} not shown. Narrow with from/to or raise limit."
        end

        # One workout: when, what it is called, how much of it is done, and where it sits
        # in the plan. `label` rather than `name` because a generated session has no name
        # of its own and is known by its program day's focus.
        #
        # Dated by `performed_or_planned_on` since #606, with the plan date after it where the
        # two differ. This line is the whole answer for a client that renders only the text,
        # and on the reporting account sessions are routinely trained two days from the day
        # they were written for -- so a lifter reading /workouts and an assistant reading this
        # were describing the same session by different days and neither said which. The
        # parenthesis is what keeps that legible rather than merely moved: a row now says the
        # session happened on Wednesday *and* that Friday is what from/to would match it on.
        def self.row(workout, on)
          view = Presenter.view_workout(workout)
          done = "#{view[:completed]} of #{view[:sets]} set(s) done"
          "  [workout #{view[:id]}] #{view[:performed_or_planned_on]}#{Presenter.planned_for(view)}" \
            "#{" #{view[:label]}" if view[:label]}: " \
            "#{done}, #{workout.status(on)}#{', finished' if view[:finished]}#{took(workout)}"
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

