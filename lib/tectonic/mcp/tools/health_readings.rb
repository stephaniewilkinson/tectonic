# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative 'freshness'
require_relative '../../body_readings'

class Tectonic < Roda
  module MCP
    module Tools
      # What an instrument actually recorded, over a window. The plain answer, and the one
      # the other two reading tools are derived from. #519.
      #
      # **A summary by default, rows on request.** A year of a twice-daily scale is seven
      # hundred rows of four numbers, and an assistant that asked "what do I weigh" would
      # spend a context window finding out. That is exactly the shape exercise_history
      # settled on for the same pressure, and the argument is the stronger one here because
      # the rows are more repetitive: a week of bodyweight is one number said seven times.
      # `include_readings` is the door for the caller that genuinely needs them -- drawing a
      # chart, or checking whether a particular morning made it across.
      #
      # **An answer per instrument, never one across them.** The summary is a count and a
      # range and a band, all of which are averages of a kind, so every one of them is
      # computed inside a single source and unit and none across two. 041 put `source` on the
      # row to make that possible and #519 asks for it in as many words; this is where it is
      # actually enforced, and it is enforced by BodyReadings.by_instrument being the only way
      # a group is ever formed rather than by each method remembering.
      #
      # **Nothing here writes.** The scale is the instrument and the app is not, so there is
      # no tool in this file or the two beside it that puts a measurement into the table --
      # #518's sync is the only thing that does. It is also what this tool asks to run before
      # it reads (#533): the fetch and this tool were built in separate worktrees and nothing
      # joined them, so the table had no filler and this reported its emptiness faithfully
      # forever. Freshness carries both halves of that call -- the asking, and what may be
      # said afterwards about how whole the window is.
      class HealthReadings < Tool
        DEFAULT_DAYS = 90

        # What a hole in the window does to *this* answer, in this tool's own terms. Every
        # figure it reports is an aggregate -- a count, the ends of a range, a band -- so a
        # window missing a page produces every one of them correctly, over a window that is
        # not the one the caller asked about. The latest reading is the one that stings: a
        # throttled fetch stops before this morning and "latest 81.4 on Tuesday" is then a
        # true sentence about a stale table.
        GAP_RISK = 'A count, a range and a band are each computed over whatever arrived, so all of ' \
                   'them would describe a smaller window than the one asked for, without saying so.'

        tool_name 'health_readings'

        title 'Measurements from a scale or a band'

        description 'Readings of one health metric for this account, newest first, as ' \
                    'recorded by whatever instrument reported them. Names to try: ' \
                    "#{BodyReadings::KNOWN.join(', ')}. Narrow with from/to (YYYY-MM-DD); " \
                    "the default window is the last #{DEFAULT_DAYS} days. " \
                    'Returns a summary by default -- how many readings, over what window, ' \
                    'the latest, the range, and how much the number moves from one reading ' \
                    'to the next -- because a year of readings is hundreds of rows that say ' \
                    'one thing. Pass include_readings for the rows themselves. ' \
                    'Results are reported separately per source and unit and are never ' \
                    'averaged across them: a scale and a caliper are different instruments ' \
                    'wearing one metric name, and so are kilograms and pounds. ' \
                    'Read-only; nothing here records a measurement.'
        scope :read
        input_schema(
          type: 'object',
          properties: { metric: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
                        source: { type: 'string' }, include_readings: { type: 'boolean' } },
          required: ['metric'], additionalProperties: false
        )

        # The fetch goes first, before the window is even worked out, because the rows it
        # writes are rows this query has to see -- a read that asked afterwards would report
        # the table as it was a moment before the readings it triggered arrived.
        def self.perform(context:, arguments:)
          metric = named(arguments)
          fresh = Freshness.checked(context, risk: GAP_RISK)
          from, to = bounds(context, arguments)
          rows = BodyReadings.in_window(context.health_metrics, metric:, from:, to:, source: arguments[:source])
          return empty(context, metric, from, to, fresh) if rows.empty?

          answer(metric, [from, to], rows, arguments, fresh)
        end

        # The window arrives as the pair it was computed as rather than as two arguments,
        # which is the same trade bodyweight_trend makes for the same reason: the alternative
        # is reading `bounds` a second time in here, and two reads of a default window is two
        # chances to resolve "today" against two different days.
        def self.answer(metric, window, rows, arguments, fresh)
          from, to = window
          instruments = BodyReadings.by_instrument(rows).map { |key, group| instrument(key, group, arguments) }
          ok(Freshness.told(summary(metric, from, to, instruments, arguments), fresh),
             structured: { metric:, asked_from: from.to_s, asked_to: to.to_s, instruments:, freshness: fresh })
        end

        # A metric name is free text in the table on purpose, so this refuses only the empty
        # string and passes everything else through. A name nobody has ever written is
        # answered by `empty` below with the list of names that do exist, which is the answer
        # a model can act on -- a refusal here would make "is there anything called
        # bodyweight" unaskable.
        def self.named(arguments)
          clean = arguments[:metric].to_s.strip
          raise Tool::Refusal, 'A reading needs a metric name.' if clean.empty?

          clean
        end

        # The last ninety days unless the caller says otherwise, rather than everything ever.
        # A default of "all of it" is the one that quietly costs the most on the account this
        # will first run against, and a caller wanting the lot can say from: '2020-01-01'.
        #
        # Parsed against the lifter's today rather than the server's, which is #349 and is why
        # `context.today` is threaded in here rather than Date.today being read.
        def self.bounds(context, arguments)
          to = arguments[:to] ? Resolver.parse_date(arguments[:to], on: context.today) : context.today
          from = arguments[:from] ? Resolver.parse_date(arguments[:from], on: context.today) : to - DEFAULT_DAYS
          [from, to]
        end

        # One instrument's answer. `readings` is the count and is always here; the rows are
        # only here when they were asked for, so a client can tell "there were none" from
        # "you did not ask for them" without a flag to read.
        def self.instrument((source, unit), group, arguments)
          view = { source:, unit:, readings: group.length, window: BodyReadings.covered(group),
                   latest: BodyReadings.reading(group.last),
                   lowest: BodyReadings.number(BodyReadings.values(group).min),
                   highest: BodyReadings.number(BodyReadings.values(group).max),
                   day_to_day: BodyReadings.day_to_day(group) }
          return view unless arguments[:include_readings]

          view.merge(values: group.reverse.map { |row| BodyReadings.reading(row) })
        end

        # Said rather than answered with an empty list, and said with the metric names this
        # account actually holds. A model that asked for `bodyweight` and got `[]` cannot tell
        # a wrong name from an empty table, and those two want opposite next moves -- one is
        # "ask again as weight" and the other is "the scale has not synced".
        #
        # Which is the answer the freshness note completes, and this is the place it matters
        # most: "no readings" is a true sentence about a revoked grant and a lifter who has
        # not weighed in, and the third possibility -- a fetch that never got through -- is
        # invisible from here. An empty answer that cannot say which of the three it is, is
        # the silent lie #533 exists to remove.
        def self.empty(context, metric, from, to, fresh)
          held = BodyReadings.metrics_held(context.health_metrics)
          ok(Freshness.told(["No #{metric} readings between #{from} and #{to}.#{held_phrase(held)}"], fresh),
             structured: { metric:, asked_from: from.to_s, asked_to: to.to_s, instruments: [],
                           metrics_held: held, freshness: fresh })
        end

        def self.held_phrase(held)
          return ' Nothing has been recorded for this account yet.' if held.empty?

          " Recorded for this account: #{held.map { |name, count| "#{name} (#{count})" }.join(', ')}."
        end

        # The prose, because plenty of clients render only the text -- #262's lesson, and a
        # tool whose whole job is a handful of numbers is the easiest of all to reduce to a
        # count nobody can act on.
        #
        # Lines rather than a finished string, so that Freshness.told can put its note in
        # front of them or behind them: where a caveat sits is part of what it says, and a
        # warning appended under three instrument lines is a warning read after the number it
        # was meant to qualify.
        def self.summary(metric, from, to, instruments, arguments)
          head = "#{metric}, #{from} to #{to}, by instrument:"
          [head, *instruments.map { |view| line(view) }, tail(arguments)]
        end

        # The band is in the sentence and not only in the payload, for the reason #519 gives:
        # a bare latest figure invites a comparison to last week's that the instrument cannot
        # resolve, and the band is the only thing in the answer that refuses it.
        def self.line(view)
          band = view[:day_to_day]
          moves = band ? ", moving about #{PLUS_MINUS}#{band} from one reading to the next" : ''
          "  #{BodyReadings.instrument_phrase(view[:source], view[:unit])}: " \
            "#{view[:readings]} reading(s), latest #{view[:latest][:value]} " \
            "on #{view[:latest][:measured_at]}, ranging #{view[:lowest]} to #{view[:highest]}#{moves}."
        end

        PLUS_MINUS = '±'

        def self.tail(arguments)
          return nil if arguments[:include_readings]

          '  Ask again with include_readings for the rows themselves.'
        end
      end
    end
  end
end

