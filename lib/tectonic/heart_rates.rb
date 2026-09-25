# frozen_string_literal: true

require_relative 'db'
require_relative 'error_reporting'
require_relative 'withings'
require_relative 'withings_connection'

class Tectonic < Roda
  # The heart rate the watch recorded during a session, and what it says about each set. #656.
  #
  # **It reports and it does not judge.** A peak and the lowest point before the next set are
  # measurements; "recovered" is a verdict about them, and verdicts belong to whoever is reading
  # -- the lifter, or the assistant they ask. Nothing here says a rest was long enough.
  #
  # **And it says how much it knows.** #579's probes found the watch samples every ten minutes
  # until it notices a workout and every fifteen seconds after. A set in the sparse stretch has
  # one reading near it or none, and a figure off one reading is not the same claim as a figure
  # off twelve, so every figure carries how many readings it rests on and the session says which
  # part of it the readings cover.
  module HeartRates
    # How far either side of the sets to ask for: the warmup before the first Done and the walk
    # away after the last are part of the session to the watch, and cost nothing to include.
    MARGIN = 5 * 60
    # Around a set: a set of five takes half a minute to a minute and Done is tapped just after
    # it, so the work sits in the minute before the tap and the heart is still climbing for a
    # few seconds after.
    BEFORE_DONE = 60
    AFTER_DONE = 30
    # Before the next set: the lowest point in the rest, taken from the end of this set's window
    # to the start of the next one's, so neither set's own climb is counted as rest.
    PLAUSIBLE = (21..259)

    Reading = Struct.new(:outcome, :stored)

    module_function

    # Ask the watch for a session's window and keep what comes back. `:stored` with a count,
    # `:none` when Withings answered with no readings, `:unreachable` when it did not answer,
    # `:absent` when there is no connection to ask through.
    def read(account_id, window)
      token = WithingsConnection.token(account_id)
      return Reading.new(:absent, 0) unless token

      body = Withings.intraday_heart_rate(token, from: window.first - MARGIN, to: window.last + MARGIN)
      return Reading.new(:unreachable, 0) unless body

      stored = store(account_id, body['series'])
      Reading.new(stored.positive? || any?(account_id, window) ? :stored : :none, stored)
    end

    # The read a match makes. #656: heart rate is not something to go and ask for, it comes with
    # the recording -- so saying "yes, that was this session" reads the session's window there
    # and then, and the recording is marked read when Withings answered, with readings or
    # without. A read Withings did not answer leaves the mark off, which is what the record page
    # reads to offer one more try; nothing else ever asks again.
    def read_for_match(account_id, workout_id, window)
      return nil unless window

      reading = read(account_id, window)
      return reading unless %i[stored none].include?(reading.outcome)

      DB[:withings_workouts].where(account_id:, workout_id:).update(heart_rate_read_at: Time.now)
      reading
    end

    # Whether the recording matched to a session still needs its heart rate read: matched, and
    # never read -- because it was matched before reads happened on matching, or because the
    # read at matching went unanswered.
    def still_to_read?(workout_id)
      !DB[:withings_workouts].where(workout_id:, heart_rate_read_at: nil).empty?
    end

    # Readings are keyed by their own instant, and one already held is left alone.
    def store(account_id, series)
      return 0 unless series.is_a?(Hash)

      series.sum { |stamp, reading| keep(account_id, stamp, reading) }
    end

    # One reading, or nothing where it is not one: a sample with no heart rate on it, or one a
    # sensor misread into a number no heart makes.
    def keep(account_id, stamp, reading)
      bpm = reading.is_a?(Hash) ? reading['heart_rate'] : nil
      return 0 unless bpm.is_a?(Integer) && PLAUSIBLE.cover?(bpm)

      written = DB[:heart_rates].insert_conflict(target: %i[account_id measured_at])
                                .insert(account_id:, measured_at: Time.at(stamp.to_i), bpm:,
                                        model: reading['model']&.to_i)
      written ? 1 : 0
    end

    def any?(account_id, window) = !within(account_id, window).empty?

    # The readings for a session's window, oldest first, as [instant, bpm] pairs.
    def within(account_id, window)
      DB[:heart_rates].where(account_id:)
                      .where(measured_at: (window.first - MARGIN)..(window.last + MARGIN))
                      .order(:measured_at).select_map(%i[measured_at bpm])
    end

    # Per completed set, keyed by the set's id: its peak and how many readings that rests on,
    # and the lowest point before the next set and how many readings that rests on. A set with
    # no stamp -- logged by hand -- has no place on the clock and gets nothing.
    def per_set(sets, readings)
      stamped = sets.select { |set| set[:completed_at] }.sort_by { |set| set[:completed_at] }
      stamped.each_with_index.to_h do |set, index|
        [set[:id], figures(set, stamped[index + 1], readings)]
      end
    end

    def figures(set, following, readings)
      done = set[:completed_at]
      around = between(readings, done - BEFORE_DONE, done + AFTER_DONE)
      rest = following ? between(readings, done + AFTER_DONE, following[:completed_at] - BEFORE_DONE) : []
      { peak: around.max, peak_readings: around.length,
        low_before_next: rest.min, rest_readings: rest.length }
    end

    def between(readings, from, to)
      readings.filter_map { |at, bpm| bpm if at.between?(from, to) }
    end

    # Which part of the session the readings cover densely: the stretch between the first and
    # last of a run of readings no more than a minute apart. The watch's workout, in practice,
    # which is the thing a lifter needs to see to know whether the early sets were measured.
    DENSE_GAP = 60

    def dense_stretch(readings)
      runs = readings.map(&:first).slice_when { |a, b| b - a > DENSE_GAP }.reject { |run| run.length < 2 }
      longest = runs.max_by { |run| run.last - run.first }
      longest && [longest.first, longest.last]
    end
  end
end

