# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  # How long a session took, and how it was spent. #281.
  #
  # Named Timing rather than Tempo, which was the first choice and is wrong here: tempo in
  # strength training is the cadence of a single rep -- 3-1-1, three seconds down, one at the
  # bottom, one up -- which is a prescription about how a set is *performed*. The exercise
  # library ships a Tempo Squat and a Tempo Bench Press, so the word is already taken in this
  # codebase for the other meaning. Timer and Countdown were refused for the opposite reason:
  # they would name the gadget in the issue's screenshot, which this deliberately is not.
  #
  # Everything here is arithmetic on sets.completed_at. Four answers come out of it:
  #
  #   overall     -- first stamp to last, or to finished_at where the lifter said so
  #   active      -- that span with the gaps too long to be training taken out (#318)
  #   turnarounds -- the interval between consecutive stamps
  #   held        -- the seconds a timed set states in duration_seconds
  #
  # **A turnaround is not a rest, and is never called one.** One tap per set is one event per
  # set, so the interval between two of them is the rest plus the working time of the set that
  # ended it. Separating those needs a Start tap on every set, which the session screen refuses
  # on the grounds its whole design rests on -- one tap, one-handed, with chalk on. Reporting
  # the sum under the name of one of its parts would be reporting a number the app cannot see,
  # so the honest word is the one used everywhere: turnaround.
  module Timing
    # Beyond this, a gap is not training. Twenty minutes is long enough to cover a genuine
    # rest before a heavy single -- five to eight minutes is the usual outer bound, and
    # nobody's programme asks for twenty -- and short enough to catch the ordinary way this
    # data goes wrong, which is a lifter who took a phone call, drove home, or left the page
    # open and came back to it after dinner.
    #
    # It is a defended guess and not a measurement, which is worth saying plainly: it will
    # discard a real nineteen-minute rest somebody took before a max attempt, and it will
    # count a nineteen-minute distraction as training. Nothing in the app can tell those
    # apart today. What it protects is the average, which one four-hour "rest" ruins
    # completely, and the discarded ones are counted rather than dropped silently so a
    # reader can see it happened.
    LONG_GAP_SECONDS = 20 * 60

    module_function

    # Everything the readers want, from rows that are already in hand. A hash rather than
    # several methods over the same array, because every caller wants more than one of these
    # and walking the sets three times to answer three questions about one session is three
    # passes for no reason.
    #
    # `overall` is nil until two sets have been stamped, or one has and the session has been
    # finished. A single completed set with nothing after it is a session with a beginning
    # and no length, and answering zero would be answering a question that was not asked.
    def session(workout, sets)
      stamps = stamps_of(sets)
      gaps = turnarounds(stamps)
      span = overall(workout, stamps)
      { overall: span, active: active(span, stamps), overall_basis: basis(workout, stamps),
        turnarounds: gaps, discarded: discarded(stamps), held: held(sets),
        typical_turnaround: median(gaps), sets_done: stamps.length }
    end

    # The stamps a session carries, oldest first. Sets with none are simply absent: a set
    # completed before #281 shipped, or one an assistant completed through a path that
    # predates it, has no time and must not be given one.
    def stamps_of(sets)
      sets.filter_map { |set| set[:completed_at] }.sort
    end

    # First stamp to last, or to finished_at when the lifter said they were done -- which is
    # the more honest end of a session whose last set was followed by ten minutes of putting
    # plates away. Nil where there is nothing to measure between.
    def overall(workout, stamps)
      return nil if stamps.empty?

      ended = finished_at(workout) || stamps.last
      seconds = (ended - stamps.first).to_i
      seconds.positive? ? seconds : nil
    end

    # The same span with the gaps too long to be training taken back out. #318.
    #
    # This reverses a decision made deliberately in #281, so the reversal is worth arguing
    # rather than just making. The original note said the overall length is not trimmed
    # because "the lifter was there; the session really did run that long". That holds for a
    # twenty-five minute gap -- somebody took a phone call and the session really did take
    # that much longer -- and it does not hold for a twenty-four hour one, which is what a
    # session logged either side of midnight produces. There is no threshold at which "the
    # lifter was there" stays true, so the line was drawn in the wrong place.
    #
    # **Both numbers are reported, and that is the whole of the fix.** This one leans on
    # LONG_GAP_SECONDS, which the constant above admits is a defended guess and not a
    # measurement -- so a version that replaced the span with this would make a guess the
    # only number anyone could see, and a real nineteen-minute rest before a max attempt
    # would silently vanish from how long the session took. Beside the raw span the guess can
    # never destroy anything: a reader seeing "9m active, 24h elapsed, 1 long gap" knows
    # exactly what happened and can judge whether that was one session or two, which is the
    # split #263 settled.
    #
    # Only the gaps *between stamps* come out. A long tail from the last set to `finished_at`
    # stays in, because finishing is a thing the lifter said rather than something inferred
    # from silence, and the ten minutes spent putting plates away is time the session cost.
    def active(span, stamps)
      return nil if span.nil?

      span - long_gaps(stamps).sum
    end

    # The gaps that were too long to be training, which two callers now want in two ways:
    # `discarded` counts them and `active` subtracts them. One method so the rule cannot
    # drift apart -- a session reporting "1 long gap" while its active time took two out
    # would be arithmetic nobody could follow.
    def long_gaps(stamps)
      consecutive(stamps).select { |seconds| seconds > LONG_GAP_SECONDS }
    end

    # Which of those two ends was used, so a reader can say "so far" about a session still
    # running rather than reporting it as a finished length.
    def basis(workout, stamps)
      return nil if stamps.empty?
      return :finished if finished_at(workout)

      :in_progress
    end

    # The intervals between consecutive stamps, with the implausible ones left out. See
    # LONG_GAP_SECONDS: a gap that long is somebody who walked away, and one of them in a
    # session is enough to make every average of the rest meaningless.
    def turnarounds(stamps)
      consecutive(stamps).select { |seconds| seconds.positive? && seconds <= LONG_GAP_SECONDS }
    end

    # How many were thrown away, reported rather than swallowed. A session showing "typical
    # turnaround 2m" with four discarded gaps is a different session from one with none, and
    # a reader who cannot see the count cannot tell them apart.
    def discarded(stamps)
      long_gaps(stamps).length
    end

    def consecutive(stamps)
      stamps.each_cons(2).map { |before, after| (after - before).to_i }
    end

    # The seconds a session actually spent under load in timed work, which is the one part
    # of "how long did the sets take" that is measured rather than inferred: a plank states
    # its own length, so it needs no clock at all. Only completed ones -- a written but
    # unlifted 60 second hold is time nobody spent.
    def held(sets)
      sets.sum { |set| set[:is_completed] && set[:duration_seconds] ? set[:duration_seconds] : 0 }
    end

    # The middle turnaround rather than the mean, because a session's gaps are not
    # symmetric: one long break between lifts pulls a mean up past every gap that actually
    # happened, and the number wanted is "what is a normal turnaround for me", which is what
    # a median answers.
    def median(gaps)
      return nil if gaps.empty?

      sorted = gaps.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0).round
    end

    # What one set of a movement costs this lifter, across every session it appears in. #263.
    #
    # The turnaround between consecutive sets of the same movement, which is the number that
    # prices a prescription: a day of five squat sets costs roughly five of these, and an
    # assistant asked "will this fit in an hour" can answer it in the lifter's own numbers
    # rather than in a constant somebody chose.
    #
    # That is the whole of why #263 stopped being an estimator. The issue asked for a model --
    # main lifts around 3 minutes, accessories 1.5, warmups 1 -- and the owner's answer was
    # that the app should represent what a lifter actually takes and let the assistant judge.
    # A median off this lifter's own sets is that representation; the constants were a guess
    # that would have been wrong for everybody in a different direction.
    #
    # Grouped by session before the subtraction, and that grouping is the point. Two sets of
    # the same movement in sessions a week apart are not a turnaround, and subtracting across
    # that boundary would report a week as a rest. Within a session, consecutive sets of the
    # movement are what a lifter experiences as "the next set" -- so a squat followed by a
    # bench and then a squat again measures the whole superset cycle, which is honest: that
    # is what the next squat set actually cost.
    #
    # Nil rather than zero where there is nothing to measure. A movement lifted once, or one
    # whose sets predate #281, has no turnaround, and a zero would be read as instantaneous.
    def between_sets_of(sets)
      gaps = sets.group_by { |set| set[:workout_id] }
                 .flat_map { |_workout_id, rows| turnarounds(stamps_of(rows)) }
      median(gaps)
    end

    # A duration as a person reads it on a gym floor: "1h 12m", "48m", "90s". Seconds only
    # under two minutes, where a turnaround is the thing being read and "2m" would round away
    # the difference between 61 and 119 seconds; minutes above that, where nobody cares about
    # the seconds and a ticking one is a distraction.
    def phrase(seconds)
      return nil if seconds.nil?
      return "#{seconds}s" if seconds < 120

      minutes = seconds / 60
      return "#{minutes}m" if minutes < 60

      "#{minutes / 60}h #{minutes % 60}m"
    end

    # finished_at off a model or a plain row, since the readers here are handed both.
    def finished_at(workout)
      workout.is_a?(Hash) ? workout[:finished_at] : workout.finished_at
    end
  end
end

