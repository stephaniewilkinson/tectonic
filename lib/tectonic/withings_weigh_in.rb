# frozen_string_literal: true

require 'bigdecimal'
require_relative 'db'

class Tectonic < Roda
  # One weigh-in as Withings sent it, written as rows: which of its numbers are kept, what each
  # is called, and how a reading becomes one row and only ever one. #605.
  #
  # Out of WithingsMeasures, which decides which stretch of time to ask for and what a piece
  # that arrived whole may claim -- the one invariant that module exists for, whose two halves
  # have to stay together. Nothing here takes part in it. This is handed a group and answers
  # how many rows were new; which window the group came from is none of its business.
  module WithingsWeighIn
    # What a body-composition scale reports, and what each reading is called here.
    #
    # The keys are Withings' measure types, which are numbers and are not guessable from
    # anything; the values are this app's names, and are the ones #519's reading tools will
    # ask for. `lean_mass` is Withings' "fat free mass" under the name #472's schema note
    # gave it -- the same quantity, and renaming it here would leave the two documents
    # describing different columns.
    #
    # All of them come back from one call, so there is no cheaper subset to ask for: a scale
    # that measures body composition measures all of it in one stand.
    #
    # ## 11, and what it is honestly worth
    #
    # **This used to say heart rate was deferred to a later ticket**, with blood pressure,
    # "with the rest of `user.activity`". #579 read Withings' own scope table and found that
    # sentence wrong on both halves: `Measure - Getmeas` is under `user.metrics`, which this
    # account already holds, and type 11 is in the Basic biomarker pack, which is the tier this
    # app is on. There was never a later ticket's worth of work in it. It is one line, it rides
    # the request `WithingsMeasures::MEASTYPES` already builds, and it needs no migration, because 041 made
    # `health_metrics.metric` free text precisely so that a new reading is a line in a hash.
    #
    # **What it will actually yield here is probably nothing, and that is not a reason to leave
    # it out.** Withings' reference says of type 11, in these words, *"Heart Pulse (bpm) - only
    # for BPM and scale devices"* -- it is a pulse the instrument takes while it is taking some
    # other reading, off a blood-pressure monitor's cuff or a scale's footpads. The reporting
    # account has no scale at all; its bodyweights are typed into the Withings app by hand, and
    # a typed weight carries no pulse. So this may well never produce a single row on this
    # account, and nothing downstream may read an empty `standing_hr` as a statement about
    # anybody's heart. It is here because it costs nothing to ask for and starts collecting on
    # its own the day a device that produces it is stood on, which is the whole of the case.
    #
    # **`standing_hr` rather than `resting_hr`**, which is the name the honesty turns on. This
    # is a pulse taken during a measurement -- standing on a scale, or sitting with a cuff on
    # -- and not a resting heart rate in the sense anybody means by that, which is taken lying
    # still and is a different number. It is not a workout heart rate either; those live on
    # `withings_workouts` with the activity they were measured over, and a name that let the
    # two be read together would put a set of squats and a weigh-in in one series.
    #
    # A type this table does not name is skipped rather than stored under its number, because a
    # metric called "91" is a row nothing will ever read on purpose. Still deliberately absent:
    # height, which is not a measurement of training and does not change (#518); blood pressure
    # types 9 and 10, which are a pair of numbers that only mean anything together and which no
    # reader here has a use for; and everything in the Total biomarker pack, which #579
    # declines on the grounds that an unentitled field comes back absent rather than refused,
    # and a value that cannot be told from silence is worse than no value.
    METRICS = {
      1 => %w[weight kg],
      5 => %w[lean_mass kg],
      6 => ['fat_ratio', '%'],
      8 => %w[fat_mass kg],
      11 => %w[standing_hr bpm],
      76 => %w[muscle_mass kg],
      77 => %w[hydration kg],
      88 => %w[bone_mass kg]
    }.freeze

    # Readings Withings itself is not sure belong to this person.
    #
    # `attrib` 1 is a device measure that may belong to another user of the same scale, and 8
    # is the unconfirmed reading from a shared device. A household scale produces these, and
    # this table has nowhere to write "probably". Storing them would put a housemate's
    # bodyweight into a lifter's trend under the lifter's own account, where it is not
    # distinguishable from their own and quietly drags the average -- and a bodyweight trend
    # that is wrong by a kilogram in a way nobody can see is worse than one with a gap in it.
    #
    # So they are skipped, and only the two values that actually say "not necessarily you" are
    # skipped: everything else is stored, including attributes this list has never heard of.
    # The failure that costs more is dropping real readings, so the unknown case falls that way.
    AMBIGUOUS = [1, 8].freeze

    module_function

    # One weigh-in: several numbers taken at one moment, which is why they share a `grpid` and
    # a date. Stored as separate rows because they are separate metrics, and joined back up by
    # `measured_at` when #519 reads body composition as a set.
    def store_group(account_id, group)
      return 0 if AMBIGUOUS.include?(group['attrib'].to_i)

      measured_at = Time.at(group['date'].to_i)
      Array(group['measures']).sum { |measure| store_measure(account_id, group, measured_at, measure) }
    end

    # Returns 1 for a row that was new and 0 for one already held, so the count a caller gets
    # is what this fetch added rather than what the window contained. Sequel's `insert` under
    # ON CONFLICT DO NOTHING answers nil when nothing was written, which is the whole check.
    def store_measure(account_id, group, measured_at, measure)
      metric, unit = METRICS[measure['type'].to_i]
      return 0 unless metric

      written = DB[:health_metrics]
                .insert_conflict(target: %i[source external_id])
                .insert(account_id:, metric:, unit:, measured_at:, source: WithingsMeasures::SOURCE,
                        value: real(measure), external_id: external_id(account_id, group, measure))
      written ? 1 : 0
    end

    # The quirk that bites. A measure is a `value` and a `unit`, and the number is
    # `value * 10 ** unit`: 81448 with unit -3 is 81.448 kg. Taking `value` at face value
    # stores a bodyweight of eighty-one thousand, which no constraint here refuses and which
    # would be discovered by a chart.
    #
    # Written as a decimal literal rather than as the arithmetic, because in Ruby `10 ** -3`
    # is a Float and `81448 * 0.001` is 81.44800000000001. Postgres would round that back to
    # three places and nobody would ever see it -- today. The column is numeric(10,3) because
    # three places is what a scale reports, not because three places is all a measurement can
    # ever need, and a Float rounded on the way in is a Float somebody later reads as exact.
    # `BigDecimal("81448e-3")` is the same number with none of that in it.
    #
    # Stored in the unit Withings gave, never converted. A kilogram turned into pounds on the
    # way in is a number the lifter never saw on their own scale, and converting back for
    # display loses a little more each time -- which is the argument 041 already made.
    def real(measure)
      BigDecimal("#{measure['value'].to_i}e#{measure['unit'].to_i}")
    end

    # The source's id for one reading, scoped to the account that fetched it.
    #
    # Withings identifies a weigh-in by `grpid` and each number within it by `type`, so that
    # pair is what makes re-reading an overlapping window a no-op instead of a duplicate.
    #
    # The account id in front of them is not decoration. The unique index is on
    # `[source, external_id]` across the whole table rather than per account, so a bare grpid
    # would mean one account's stored reading silently swallowing another's -- either because
    # Withings' ids are not as global as they look, or because two accounts here are connected
    # to one Withings login, which is what somebody with a second account does on purpose. In
    # both cases the symptom is readings that simply never arrive for the second lifter, and
    # nothing anywhere raises.
    def external_id(account_id, group, measure)
      "#{account_id}:#{group['grpid']}:#{measure['type'].to_i}"
    end
  end
end

