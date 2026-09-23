# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative '../../body_readings'

class Tectonic < Roda
  module MCP
    module Tools
      # Fat mass, lean mass and the percentage from one weigh-in, together. #519.
      #
      # **Together is the whole design.** A body-fat percentage is a ratio, so it carries the
      # weight it was taken at inside it, invisibly. Read on its own it invites the comparison
      # that ruins it: 27.9% this week against 28.4% a fortnight ago reads as half a point of
      # progress, and if the two mornings were 81 kg and 84 kg apart it is not a comparison at
      # all -- the same fat mass over a different denominator. Returning the set means the
      # denominator is never missing, and a reader who wants to compare has both halves of
      # both readings in front of them.
      #
      # **One weigh-in, not one day.** BodyReadings clusters rows within five minutes of each
      # other, because a scale writes the whole group at one instant and anything looser would
      # let an evening weigh-in supply the weight for a morning's fat reading. A lifter who
      # steps on twice a day is exactly the person this would mislead.
      #
      # **The band travels with the percentage.** #519 is explicit: "27.9%, day-to-day
      # variation around +/-1.5%" rather than a bare figure, because bioimpedance is sensitive
      # to hydration and recent food, and a bare number invites an assistant to compare it to
      # last week's and call it progress when the instrument cannot resolve the difference.
      # The band here is measured from this account's own weigh-ins on the same instrument
      # rather than from a published figure for the hardware, so it describes this scale in
      # this bathroom with this person's habits.
      #
      # **Nothing here says what the number should be.** No target composition, no opinion on
      # a direction. Same split as block_progress: report the figure, the sample size and the
      # uncertainty, and leave the judgement to whoever is reading.
      class BodyComposition < Tool
        DEFAULT_BAND_DAYS = 90
        BAND_DAYS = (7..730)

        tool_name 'body_composition'

        title 'Body composition from one weigh-in'

        description 'Fat mass, lean mass and body-fat percentage from a single weigh-in, ' \
                    'returned together with the bodyweight they were taken at. The most ' \
                    'recent weigh-in by default; pass on (YYYY-MM-DD) for the last one at or ' \
                    'before that day. The percentage comes with the day-to-day variation ' \
                    "measured from this account's own weigh-ins on the same instrument, " \
                    'because bioimpedance moves with hydration and recent food -- a ' \
                    'difference smaller than that band is not a change this scale can see. ' \
                    'Set how far back the band is measured over with days (default ' \
                    "#{DEFAULT_BAND_DAYS}). Reported separately per source and never mixed " \
                    'across them. Read-only, and it does not say what the figures should be.'
        scope :read
        input_schema(
          type: 'object',
          properties: { on: { type: 'string' }, source: { type: 'string' }, days: { type: 'integer' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          on = arguments[:on] ? Resolver.parse_date(arguments[:on], on: context.today) : context.today
          days = band_days(arguments)
          rows = BodyReadings.of_metrics(context.health_metrics, BodyReadings::COMPOSITION,
                                         from: on - days, to: on, source: arguments[:source])
          return empty(on) if rows.empty?

          answer(on, days, rows)
        end

        def self.answer(on, days, rows)
          instruments = BodyReadings.by_source(rows).map { |source, group| instrument(source, group, days) }
          ok(summary(on, instruments), structured: { on: on.to_s, band_days: days, instruments: })
        end

        # Clamped rather than refused, on exercise_history's rule for `limit`: a caller who
        # asks for three days of history to measure a band over has asked for something this
        # tool cannot do honestly, and the nearest thing it can do is more use than an error.
        def self.band_days(arguments)
          (arguments[:days] || DEFAULT_BAND_DAYS).clamp(BAND_DAYS.min, BAND_DAYS.max)
        end

        # One instrument's latest weigh-in, and the percentage's band measured across every
        # weigh-in this instrument recorded in the window.
        #
        # The band is computed over the window and the figures come from one weigh-in inside
        # it, which is the asymmetry worth naming: a band from a single morning would be no
        # band at all, and figures averaged across the window would be the thing this tool
        # exists to refuse.
        def self.instrument(source, group, days)
          weigh_ins = BodyReadings.weigh_ins(group)
          latest = weigh_ins.first
          { source:, measured_at: BodyReadings.instant(latest.values.first[:measured_at]),
            **BodyReadings::MASSES.to_h { |metric| [metric.to_sym, measure(latest[metric])] },
            missing: BodyReadings::MASSES.reject { |metric| latest[metric] },
            body_fat_percent: percent_view(group, latest, days) }
        end

        # A stored figure as a value and the unit it was stored in, never converted. 041's
        # comment settles that: a kilogram turned into pounds on the way in is a number the
        # lifter never saw, and this tool is the one that would be most tempted to do it
        # anyway, because the app's own weights are pounds. An assistant can convert; the
        # record should not.
        def self.measure(row)
          return nil unless row

          { value: BodyReadings.number(row[:value]), unit: row[:unit] }
        end

        # The percentage with everything needed to know what it is worth: which kind it is,
        # how far it moves between weigh-ins, and how many weigh-ins that was measured over.
        #
        # `weigh_ins` is in the payload because a band from four readings and a band from
        # forty are not the same claim, which is exercise_history's argument for putting the
        # set count beside every windowed max.
        def self.percent_view(group, latest, days)
          percent = BodyReadings.percentage(latest)
          return nil unless percent

          series = BodyReadings.percentage_series(group)
          percent.merge(day_to_day: BodyReadings.day_to_day(series), weigh_ins: series.length,
                        measured_over_days: days)
        end

        def self.empty(on)
          ok("No body composition readings on or before #{on}. A weigh-in has to have " \
             'arrived from a scale or been recorded by hand before there is anything to ' \
             'read back.',
             structured: { on: on.to_s, instruments: [] })
        end

        # The prose, because plenty of clients render only the text -- #262 -- and because a
        # percentage is the single figure in this app most likely to be lifted out of a
        # sentence and quoted on its own. Everything that qualifies it is in the same line.
        def self.summary(on, instruments)
          ["Body composition as of #{on}, by instrument:",
           *instruments.map { |view| line(view) },
           '  Each line is one weigh-in. A percentage compared against one taken at a ' \
           'different bodyweight is two different measurements, not a change.'].join("\n")
        end

        def self.line(view)
          figures = [measure_phrase('weight', view[:weight]), measure_phrase('fat mass', view[:fat_mass]),
                     measure_phrase('lean mass', view[:lean_mass])].compact
          "  #{view[:source]} on #{view[:measured_at]}: " \
            "#{figures.join(', ')}#{percent_phrase(view[:body_fat_percent])}.#{missing_phrase(view[:missing])}"
        end

        def self.measure_phrase(label, measure)
          measure && "#{label} #{measure[:value]} #{measure[:unit]}"
        end

        # The clause #519 is really about. The band is never dropped when it exists, and when
        # it does not the sentence says so rather than going quiet -- a percentage printed
        # with no qualification at all is the reading this tool is written to prevent.
        def self.percent_phrase(percent)
          return '' unless percent

          band = percent[:day_to_day]
          spread = if band
                     ", day-to-day variation around #{PLUS_MINUS}#{band}% " \
                       "across #{percent[:weigh_ins]} weigh-in(s)"
                   else
                     ', with too few weigh-ins to say how much it moves between them'
                   end
          ", body fat #{percent[:value]}% (#{percent[:basis]})#{spread}"
        end

        PLUS_MINUS = '±'

        # Named rather than silently absent. A scale that reports a weight and no impedance
        # reading -- which is what a bare weigh-in with bare feet on a carpet gives -- would
        # otherwise look identical to one whose lean mass simply was not asked for.
        def self.missing_phrase(missing)
          return '' if missing.empty?

          " Not recorded at this weigh-in: #{missing.join(', ')}."
        end
      end
    end
  end
end

