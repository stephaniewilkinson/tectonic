# frozen_string_literal: true

require 'date'
require 'time'
require_relative 'db'
require_relative 'plates'
require_relative 'withings_measures'
require_relative 'withings_sleep'

class Tectonic < Roda
  # What the scale said, and how much of what it said is worth reading. #519.
  #
  # 041 made somewhere to put a bodyweight and #518 fills it. This is the arithmetic over
  # what is in there, kept out of the three tools that read it because all three need the
  # same two ideas -- an instrument, and a band -- and three copies of either would be three
  # chances to average something that does not average.
  #
  # ## An instrument is a source *and* a unit
  #
  # 041's own comment says why `source` is on the row from the start: "a scale's body-fat
  # figure and a caliper's are different measurements wearing one name", so a reader that
  # cannot tell them apart would average two things that do not average. The unit is the
  # other half of the same argument and it is the easier one to walk into, because one source
  # supplies both: a lifter who flips the Withings app from kilograms to pounds leaves a
  # history in which 81.4 and 179.5 are the same morning. A mean over those two is not a
  # heavier lifter, it is 130 of nothing.
  #
  # So everything here keys on the pair, `by_instrument` is the only way in, and every number
  # this module hands back belongs to exactly one of them. That is a structural guarantee
  # rather than a rule each tool remembers, which is the same reason RequestContext hands out
  # datasets instead of an account_id.
  #
  # ## The band is deliberately too wide
  #
  # `day_to_day` is the mean absolute difference between one reading and the next, and that
  # is not a clean noise estimate: it contains real drift as well as hydration, and a lifter
  # who weighs morning and evening will see the day's food in it. Both of those inflate it.
  #
  # That is the direction to be wrong in. The band exists to stop a reader calling a 0.3 kg
  # move progress, so an estimate that overstates how little the instrument can resolve
  # refuses a conclusion that a tighter estimate would have allowed. A standard deviation of
  # residuals around the rolling mean was the other candidate and it is narrower, more
  # assumption-laden -- it wants readings evenly spaced and a trend that is locally straight,
  # and a real weigh-in history is neither -- and harder to explain in the one sentence a
  # reader gets. "How much it moves from one reading to the next" needs no explanation at all.
  #
  # ## Nothing here judges
  #
  # There is no goal weight, no target rate, and no opinion about which direction is the good
  # one. That is #308's split, restated: the app reports the gap and the days and the sample
  # size, and the assistant reading them decides what they mean. It matters more here than it
  # did for a training max, because bodyweight is the number a person is most likely to have
  # already decided how to feel about.
  module BodyReadings
    # The metrics the reading tools name in their descriptions. Not a constraint -- 041 stores
    # `metric` as free text on purpose, "because the set grows with every instrument and a
    # migration per metric is a migration nobody will write" -- so this is the list a model is
    # told about, and anything else a source writes is still readable by naming it.
    #
    # Two names in it were names nothing writes, which is the one thing this list must not
    # contain: a model told to try `sleep_minutes` or `resting_hr` gets silence from them
    # forever, and silence is what it would also get from a metric that genuinely has no rows
    # yet. They were written here before either read existed, and both reads have since
    # arrived under different names.
    #
    # `sleep_minutes` is now `sleep_hours` and `sleep_window_hours`, because #579's read
    # stores hours -- a night is said in hours by the lifter and by Health Mate alike.
    # `resting_hr` is now `standing_hr`, which is the name #581 chose for `getmeas` type 11
    # and chose carefully: a pulse taken standing on a scale or sitting with a cuff on is not
    # a resting heart rate in the sense anybody means by that. That file declined to claim
    # `resting_hr`; this stops advertising it.
    #
    # Derived from the writers rather than kept by hand, because by hand it drifted on four
    # names of eight (#585): `muscle_mass`, `hydration` and `bone_mass` had been written since
    # #518 and never offered, so a model could read them only by already knowing they existed.
    # A metric is one line in `WithingsMeasures::METRICS` or one constant in `WithingsSleep`,
    # and now that line is also what makes it known. Read off constants, not the table, so it
    # costs nothing per request and does not hide a metric just because nobody has one yet.
    KNOWN = (WithingsMeasures::METRICS.values.map(&:first) + [WithingsSleep::SLEPT, WithingsSleep::WINDOW]).freeze

    # The three figures a body composition read reports, in the order a reader wants them:
    # the bodyweight first, because it is the denominator everything else is read against.
    MASSES = %w[weight fat_mass lean_mass].freeze

    # What a weigh-in is fetched as. `fat_ratio` is in the query and not in MASSES because
    # Withings reports a percentage of its own alongside the masses -- it is an alternative
    # spelling of a figure that is reported anyway, rather than a fourth measurement, so a
    # weigh-in without one is not missing anything. See `percentage` for why a measured one
    # beats a derived one.
    COMPOSITION = (MASSES + ['fat_ratio']).freeze

    # How many days a rolling trend looks back over. A week, because the thing it is smoothing
    # out is a weekly shape: a lifter eats differently at the weekend, and a five-day mean
    # would carry that difference into the trend as signal.
    DEFAULT_WINDOW_DAYS = 7
    WINDOW_DAYS = (2..90)

    # How far apart two readings may be and still count as consecutive for the band. Three
    # days rather than one, because a lifter who skips the scale on a Sunday has not stopped
    # weighing, and rather than a week, because the gap over which a real change accumulates
    # is exactly what the band must not swallow.
    NEIGHBOURING_DAYS = 3

    # How close together two readings have to be to be one weigh-in. Withings writes a body
    # composition group with a single instant on every row, so exact equality would do for the
    # source that exists today -- and would quietly stop working for a hand-entered set typed
    # over a minute, or a bridge that stamps each metric as it converts it. Five minutes is
    # longer than any of those and far shorter than the gap between two real weigh-ins.
    WEIGH_IN_SECONDS = 300

    # The most rows any one tool will pull back. The trend is quadratic in the number of
    # readings it smooths, and more to the point a caller asking for five years of a
    # twice-daily scale is asking for a number, not for forty thousand rows to arrive in a
    # context window. Reached rather than exceeded is reported, so a truncated answer says so.
    MAX_ROWS = 2000

    DAY = 86_400

    module_function

    # One metric's readings, newest first, inside a window. The dataset is handed in rather
    # than an account_id, so this cannot be pointed at another account's measurements: the
    # only dataset a tool has is the one RequestContext already filtered.
    def in_window(readings, metric:, from: nil, to: nil, source: nil)
      of_metrics(readings, [metric], from:, to:, source:)
    end

    # Several metrics at once, for the read that wants a whole weigh-in rather than one
    # column of it.
    def of_metrics(readings, metrics, from: nil, to: nil, source: nil)
      rows = readings.where(metric: metrics.map(&:to_s))
      rows = rows.where(source: source.to_s) if source
      bounded(rows, from, to).order(Sequel.desc(:measured_at), Sequel.desc(:id)).limit(MAX_ROWS).all
    end

    def bounded(rows, from, to)
      opened = opening(from)
      closed = closing(to)
      rows = rows.where { measured_at >= opened } if opened
      rows = rows.where { measured_at < closed } if closed
      rows
    end

    # What this account has ever measured, as metric => how many. What a tool says instead of
    # a bare "nothing found": a model that asked for `bodyweight` and got silence cannot tell
    # a wrong metric name from an empty table, and those want opposite next moves.
    def metrics_held(readings)
      readings.group_and_count(:metric).order(:metric).to_h { |row| [row[:metric], row[:count]] }
    end

    # The readings grouped by the instrument that produced them, each group chronological.
    # Every statistic below takes one group, which is what makes "never average across
    # sources" true by construction rather than by everybody remembering it.
    def by_instrument(rows)
      rows.group_by { |row| [row[:source], row[:unit]] }
          .transform_values { |group| group.sort_by { |row| row[:measured_at] } }
    end

    # The one grouping that keys on the source alone, for the read that wants a whole weigh-in
    # rather than one column of it.
    #
    # It is not a hole in the rule above. A weigh-in is several metrics in several units by
    # construction -- the mass is in kilograms and the ratio is a percentage -- so pairing the
    # unit into the key would split one morning's reading into three groups that can never be
    # reassembled, which is the exact failure #519 asks this tool to prevent. Nothing in this
    # grouping is averaged across units: the masses are reported as they were stored, and the
    # only division done to them refuses a fat mass and a weight that disagree about the unit.
    def by_source(rows)
      rows.group_by { |row| row[:source] }
          .transform_values { |group| group.sort_by { |row| row[:measured_at] } }
    end

    # A window's two ends as instants at the lifter's midnight, which is what the timestamp
    # column wants and what no caller should have to remember. `closing` is a day later than
    # the date asked for and compared with `<`, so a window ending 2026-09-22 includes that
    # morning's weigh-in -- the same arithmetic exercise_history does on a workout date, for
    # the same reason.
    def opening(date) = date&.to_time

    def closing(date) = date && (date + 1).to_time

    # One row as a reader sees it. `value` through `number` because the column is
    # numeric(10,3): Sequel hands back a BigDecimal and BigDecimal serialises to JSON as the
    # string "0.814e2", which is #256's bug and is waiting in every new payload.
    def reading(row)
      { value: number(row[:value]), unit: row[:unit], source: row[:source],
        measured_at: instant(row[:measured_at]), external_id: row[:external_id] }
    end

    # The window a group of readings actually covers, which is not the window that was asked
    # for and is the one a reader needs: "28 readings" over four days and over four months are
    # different claims about the same count.
    def covered(group)
      { from: instant(group.first[:measured_at]), to: instant(group.last[:measured_at]),
        days: ((group.last[:measured_at] - group.first[:measured_at]) / DAY).round }
    end

    # The rolling mean, one point per day, each the mean of everything in the `days` before it
    # and including it. Trailing rather than centred: a centred window cannot produce a point
    # for today until half a window has gone by, and today is the point every caller is
    # actually asking about.
    #
    # One point per day because more than one is noise pretending to be resolution -- two
    # weigh-ins on a Tuesday produce two nearly identical trailing means, and a series
    # carrying both reads as a day with twice the evidence. The last of the day wins.
    def rolling(group, days: DEFAULT_WINDOW_DAYS)
      span = days * DAY
      points = group.map do |row|
        inside = group.select { |other| covers?(other, row, span) }
        { on: day(row[:measured_at]), value: number(mean(values(inside)), 2), readings: inside.length }
      end
      points.to_h { |point| [point[:on], point] }.values
    end

    def covers?(other, row, span)
      other[:measured_at] <= row[:measured_at] && other[:measured_at] > row[:measured_at] - span
    end

    # How much the number moves from one reading to the next: the band. Nil where no two
    # readings are close enough together to say, which is an honest answer and the one a
    # single weigh-in deserves -- a zero there would read as a perfect instrument.
    #
    # Pairs further apart than NEIGHBOURING_DAYS are dropped rather than divided down by their
    # gap. Dividing assumes the value wanders like a random walk, which is an assumption about
    # physiology that this module is in no position to make, and it would turn one January
    # reading beside one June reading into a confident daily figure.
    def day_to_day(group, gap_days: NEIGHBOURING_DAYS)
      span = gap_days * DAY
      steps = group.each_cons(2).filter_map do |before, after|
        (after[:value].to_f - before[:value].to_f).abs if after[:measured_at] - before[:measured_at] <= span
      end
      steps.empty? ? nil : number(mean(steps), 2)
    end

    # One weigh-in's worth of rows: everything stamped within WEIGH_IN_SECONDS of the newest
    # reading in the group. Newest first, so `first` is the weigh-in a caller asking for "now"
    # means.
    #
    # Rows rather than a time range, because what a caller wants from this is the set -- the
    # weight, the fat mass and the lean mass that were on the scale at once. Reading the
    # percentage off one weigh-in and the weight off another is the mistake #519 names, and it
    # is easiest to make when the two arrive from separate queries.
    def weigh_ins(group)
      group.reverse.slice_when { |later, earlier| later[:measured_at] - earlier[:measured_at] > WEIGH_IN_SECONDS }
           .map { |rows| rows.to_h { |row| [row[:metric], row] } }
    end

    # The body fat figure for one weigh-in, and which kind it is.
    #
    # A measured percentage beats a derived one. Withings reports a fat ratio of its own,
    # computed inside the scale from the impedance it actually saw, and recomputing it from
    # two rounded masses would produce a second number a tenth away from the first for no
    # gain. Where there is none -- a caliper reading, a manual entry -- fat mass over weight
    # is the arithmetic anybody would do by hand, and saying which of the two this is stops a
    # reader treating them as one series.
    #
    # Nil rather than a guess where the weigh-in has a fat mass and no weight beside it: that
    # is exactly the comparison across bodyweights #519 exists to prevent, and the app would
    # be making it itself.
    def percentage(weigh_in)
      measured = weigh_in['fat_ratio']
      return { value: number(measured[:value], 1), basis: 'measured' } if measured

      derived(weigh_in['fat_mass'], weigh_in['weight'])
    end

    def derived(fat, mass)
      return nil unless divisible?(fat, mass)

      { value: number(fat[:value].to_f / mass[:value] * 100, 1), basis: 'derived from fat mass and weight' }
    end

    # Both halves present, in one unit, with a denominator to divide by. The unit check is the
    # one that looks paranoid and is not: a source that changed units mid-history has a fat
    # mass in kilograms and a bodyweight in pounds sitting in the same window, and 22.7 over
    # 179.5 is a body-fat figure of 12.6% that belongs to nobody.
    def divisible?(fat, mass)
      !fat.nil? && !mass.nil? && fat[:unit] == mass[:unit] && mass[:value].to_f.positive?
    end

    # The percentage as a series, so the band on it is measured the same way the band on a
    # weight is. Derived per weigh-in rather than from two separate series, which is the
    # module's own rule applied to itself: a mean of percentages and a percentage of means
    # differ, and only the first is a thing that was ever on the scale.
    def percentage_series(group)
      weigh_ins(group).reverse.filter_map do |weigh_in|
        percent = percentage(weigh_in)
        next unless percent

        { value: percent[:value], measured_at: weigh_in.values.first[:measured_at] }
      end
    end

    def values(group) = group.map { |row| row[:value].to_f }

    def mean(numbers) = numbers.sum / numbers.length.to_f

    # A number a JSON client can do arithmetic on, and a person can read. Whole numbers come
    # back as Integers on Plates.numeric's rule, so a bodyweight of exactly 81 is "81" rather
    # than "81.0", and nothing anywhere in a payload is a BigDecimal.
    def number(value, places = 3)
      value && Plates.numeric(Rational(value.to_f.round(places).to_s))
    end

    def instant(time) = time&.to_time&.iso8601

    def day(time) = time&.to_date&.strftime('%Y-%m-%d')

    # A signed number, because the sign is the whole message and a leading "+" is what stops
    # "0.7" over a fortnight reading as a loss to somebody scanning.
    def signed(value) = value && (value.negative? ? value.to_s : "+#{value}")

    # How an instrument is named in a sentence. The unit is in there because it is half of
    # what makes the instrument one: a reader seeing two withings lines wants to know
    # immediately that one of them is in pounds.
    def instrument_phrase(source, unit) = "#{source} (#{unit})"
  end
end

