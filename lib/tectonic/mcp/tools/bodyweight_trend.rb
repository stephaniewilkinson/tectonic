# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'support'
require_relative '../../body_readings'

class Tectonic < Roda
  module MCP
    module Tools
      # What bodyweight is doing, and how much of the movement is the scale rather than the
      # lifter. #519.
      #
      # This is the tool that answers "am I gaining", and the reason it has to exist is that
      # nothing simpler can. A single reading cannot: it is one morning's hydration. Two
      # readings a day apart cannot either, and that is the dangerous case, because two
      # numbers look exactly like a trend -- 81.9 on Monday and 81.2 on Tuesday is a
      # confident-looking 0.7 kg that is mostly water and yesterday's dinner. A rolling mean
      # is the smallest honest answer, and it is only honest with the band beside it.
      #
      # **The band is the point, not a footnote.** `day_to_day` says how far the number moves
      # between one reading and the next, and `change_exceeds_day_to_day` says whether the
      # change across the whole window is bigger than that. That second field is a claim about
      # the instrument and not about the training: it says what this measurement can and
      # cannot resolve, in the same spirit as block_progress reporting the gap and the days
      # and refusing to say whether the lifter is behind.
      #
      # **What it deliberately does not carry.** No goal weight, no target rate of loss, and
      # no view on whether a direction is the right one. `per_week` is the observed rate, an
      # arithmetic restatement of a change and a number of days, and there is nothing beside
      # it saying what that rate ought to be. Those are coaching judgements over honest
      # numbers, which is the assistant's job and not the app's -- Goal's own comment makes
      # the same argument about pounds divided by weeks, and bodyweight is the number a person
      # is most likely to have already decided how to feel about.
      class BodyweightTrend < Tool
        DEFAULT_DAYS = 90
        DEFAULT_METRIC = 'weight'

        tool_name 'bodyweight_trend'

        title 'Bodyweight trend and its noise band'

        description 'What a measured number is doing over a window, as a rolling mean, with ' \
                    'the day-to-day variation that says how much of the movement is noise. ' \
                    'Defaults to weight; any stored metric can be named. Reports the trend ' \
                    'at the start and end of the window, the change between them, the ' \
                    'observed rate per week, and whether that change is larger than the ' \
                    'band a single reading moves in -- a change inside the band is one this ' \
                    'instrument cannot tell from nothing. Narrow with from/to (YYYY-MM-DD) ' \
                    "and set the smoothing with days (default #{BodyReadings::DEFAULT_WINDOW_DAYS}). " \
                    'Summary by default; pass include_series for the daily trend points. ' \
                    'Reported separately per source and unit, never averaged across them. ' \
                    'It reports the numbers and does not say whether the direction is good, ' \
                    'what the weight should be, or how fast it should change.'
        scope :read
        input_schema(
          type: 'object',
          properties: { metric: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
                        days: { type: 'integer' }, source: { type: 'string' },
                        include_series: { type: 'boolean' } },
          required: [], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          metric = (arguments[:metric] || DEFAULT_METRIC).to_s.strip
          from, to = bounds(context, arguments)
          rows = BodyReadings.in_window(context.health_metrics, metric:, from:, to:, source: arguments[:source])
          return empty(metric, from, to) if rows.empty?

          answer(metric, from, to, rows, arguments)
        end

        # `asked_from` and `asked_to` are the window the caller named, which is not the window
        # each instrument actually covers -- that one is on every instrument, because "28
        # readings" over four days and over four months are different claims.
        def self.answer(metric, from, to, rows, arguments)
          instruments = BodyReadings.by_instrument(rows).map { |key, group| instrument(key, group, arguments) }
          ok(summary(metric, from, to, instruments),
             structured: { metric:, asked_from: from.to_s, asked_to: to.to_s,
                           window_days: smoothing(arguments), instruments: })
        end

        # Ninety days unless asked otherwise, which is long enough for a bodyweight trend to
        # be a trend and short enough that the answer is about now. Read against the lifter's
        # today (#349) rather than the server's, like every other window in this directory.
        def self.bounds(context, arguments)
          to = arguments[:to] ? Resolver.parse_date(arguments[:to], on: context.today) : context.today
          from = arguments[:from] ? Resolver.parse_date(arguments[:from], on: context.today) : to - DEFAULT_DAYS
          [from, to]
        end

        # Clamped rather than refused. A caller asking for a one-day mean is asking for the
        # raw readings and should get the nearest thing this tool can honestly give, and a
        # caller asking for a year of smoothing on ninety days of data gets one point. The
        # bounds are in BodyReadings beside the default so the number and its range cannot
        # drift into two files.
        def self.smoothing(arguments)
          (arguments[:days] || BodyReadings::DEFAULT_WINDOW_DAYS).clamp(BodyReadings::WINDOW_DAYS.min,
                                                                        BodyReadings::WINDOW_DAYS.max)
        end

        # One instrument's trend. The series is computed either way -- the ends of it are the
        # answer -- and only carried out of the door when it was asked for, which is the
        # summary-by-default rule: a year at one point a day is three hundred objects saying
        # what two of them already said.
        def self.instrument((source, unit), group, arguments)
          series = BodyReadings.rolling(group, days: smoothing(arguments))
          moved = movement(series)
          view = { source:, unit:, readings: group.length, window_days: smoothing(arguments),
                   window: BodyReadings.covered(group), opened: series.first, latest: series.last }
                 .merge(moved).merge(resolution(group, moved[:change]))
          arguments[:include_series] ? view.merge(series:) : view
        end

        # The change across the window, and the same change as a weekly rate.
        #
        # Nil rather than zero where the window holds a single day: one point has not changed
        # by nothing, it has not changed at all, and a zero there would read as a plateau
        # somebody could act on. `per_week` is nil for the same day, because the rate over
        # zero days is not a large number, it is not a number.
        def self.movement(series)
          return { change: nil, days: 0, per_week: nil } if series.length < 2

          days = (Date.parse(series.last[:on]) - Date.parse(series.first[:on])).to_i
          change = BodyReadings.number(series.last[:value] - series.first[:value], 2)
          { change:, days:, per_week: rate(change, days) }
        end

        # The observed rate, and nothing that says what it ought to be. Nil over zero days
        # rather than an infinity or a zero: several readings inside one day have not produced
        # a weekly rate, however many of them there are.
        def self.rate(change, days)
          days.positive? ? BodyReadings.number(change / days.to_f * 7, 2) : nil
        end

        # What the instrument can resolve, beside what it measured.
        #
        # `change_exceeds_day_to_day` is a boolean and it is worth being careful about what it
        # claims. It does not say the change is real, meaningful, or good. It says the change
        # is bigger than the amount this number moves between two consecutive readings, which
        # is the one thing about it the app is in a position to know. False on a 0.3 kg move
        # in a scale that swings 0.5 kg overnight is the answer that stops "down 0.3, nice
        # week" being said about hydration.
        #
        # Nil where there is no band -- one reading, or readings too far apart to pair --
        # because "we cannot tell" and "it does not exceed" are different answers and only one
        # of them is true there.
        def self.resolution(group, change)
          band = BodyReadings.day_to_day(group)
          { day_to_day: band,
            change_exceeds_day_to_day: (band && change ? change.abs > band : nil) }
        end

        def self.empty(metric, from, to)
          ok("No #{metric} readings between #{from} and #{to}, so there is no trend to " \
             'report. A trend needs several readings across the window; one reading is a ' \
             'morning, not a direction.',
             structured: { metric:, asked_from: from.to_s, asked_to: to.to_s, instruments: [] })
        end

        # The prose, because many clients render only the text (#262) -- and because this is
        # the tool where the text and the payload disagreeing would matter most. A sentence
        # carrying the change without the band is the misreading #519 is about, so the band is
        # in every line that has one.
        def self.summary(metric, from, to, instruments)
          ["#{metric} trend, #{from} to #{to}, by instrument:",
           *instruments.map { |view| line(view) },
           '  Whether that direction is the right one is not something these numbers say.'].join("\n")
        end

        def self.line(view)
          "  #{BodyReadings.instrument_phrase(view[:source], view[:unit])}: " \
            "#{view[:window_days]}-day mean #{view[:opened][:value]} to #{view[:latest][:value]}" \
            "#{over(view)}, from #{view[:readings]} reading(s).#{band_phrase(view)}"
        end

        def self.over(view)
          return '' unless view[:change]

          rate = view[:per_week] ? ", #{BodyReadings.signed(view[:per_week])} per week" : ''
          " over #{view[:days]} day(s), a change of #{BodyReadings.signed(view[:change])}#{rate}"
        end

        # The sentence that does the refusing. Spelled out rather than left to the boolean,
        # because a client rendering only text never sees the boolean and the whole point of
        # #519 is that this clause travels with the number.
        def self.band_phrase(view)
          band = view[:day_to_day]
          return ' Too few readings close together to say how much of that is noise.' unless band

          moves = " Day to day it moves about #{PLUS_MINUS}#{band}"
          return "#{moves}, and no change has been measured across the window." if view[:change].nil?

          "#{moves}, so this change is #{view[:change_exceeds_day_to_day] ? 'larger than' : 'inside'} the noise."
        end

        PLUS_MINUS = '±'
      end
    end
  end
end

