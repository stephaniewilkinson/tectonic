# frozen_string_literal: true

require_relative 'session_length'
require_relative 'timing'

class Tectonic < Roda
  # Why a session ran long, from what was already stored. #409.
  #
  # When a session ends early or runs over, three causes look identical in the log, and they
  # are already distinguishable from what is on the rows:
  #
  #   * **The rests ran long.** A gap above what the set was prescribed.
  #   * **The session was overprescribed.** More work was written than the prescribed rests
  #     allow in the time the session actually ran.
  #   * **It started late.** Only the lifter knows what late means, so this does not model it
  #     and never will. There is no column for "when I meant to be there", inferring one from
  #     a habit would be the app deciding what somebody's evening is for, and a wrong guess
  #     about lateness reads as an accusation.
  #
  # **This needed one thing that did not exist when #409 was written**: a prescribed rest to
  # compare against. #281 added it, so "the rests ran long" is a direct comparison rather than
  # a threshold somebody chose.
  #
  # ## The subtraction that makes the comparison fair
  #
  # A turnaround is not a rest. It is the gap between two completions, which is the rest plus
  # the working time of the set that ended it -- `lib/tectonic/timing.rb` is careful never to
  # call it a rest for exactly this reason. So comparing a raw turnaround against
  # planned_rest_seconds would report every set on a three-minute prescription as over by the
  # forty seconds the next set took to perform, and a session lifted exactly as written would
  # come back as "18 sets over the prescribed rest".
  #
  # The working time comes out first, using SessionLength's own declared constant. That means
  # one constant nobody measured is inside this comparison, and it is the honest trade: the
  # alternative is a comparison that is wrong for every session. It is also the same constant
  # #408 prices a session with, so the estimate and the diagnosis cannot disagree about how
  # long a set takes.
  #
  # ## What it reports and what it concludes
  #
  # It concludes nothing. It counts how many rests ran over, names the longest single gap, and
  # says how much was left unfinished -- three facts, and the reader decides what they add up
  # to. A session that ran long and still moved a training max is a good session, which is not
  # a judgement this file is in a position to make.
  module SessionDiagnosis
    # What a session has to say for itself. Every field is nil or zero where there is nothing
    # to report, so a session lifted exactly as written says nothing rather than saying
    # everything was fine in four clauses.
    Finding = Struct.new(:over_rest, :compared, :longest_gap, :unfinished, :prescribed_seconds, :actual_seconds) do
      # Whether there is anything here worth printing. A session with every set done, no rest
      # over its prescription and no notable gap has nothing to explain.
      def anything? = over_rest.positive? || unfinished.positive? || !longest_gap.nil?

      # More was written than the time the session ran allows. Only answerable once there is
      # both a prescription to price and a session to price it against -- and deliberately not
      # a verdict: it is the arithmetic, said out loud.
      def overprescribed?
        return false unless prescribed_seconds && actual_seconds

        prescribed_seconds > actual_seconds
      end
    end

    # A gap worth naming on its own. Below this, a long rest is a rest; above it, it is the
    # thing that explains the session and belongs in the sentence.
    #
    # Five minutes is a defended guess and not a measurement, in the same way LONG_GAP_SECONDS
    # is. It sits where it does because a prescribed rest tops out at eight minutes for a
    # heavy single, so a *gap* worth remarking on has to be above the ordinary top of the
    # range without being so high that only the twenty-minute gaps Timing already discards can
    # reach it.
    NOTABLE_GAP_SECONDS = 5 * 60

    module_function

    # What this session has to say about how it went, given a way of asking what this lifter
    # usually takes between sets of a movement -- the same callable #408's estimate takes, and
    # for the same reason.
    #
    # `active_seconds` is passed in rather than recomputed, and it comes from the `Timing`
    # hash the caller already has. Working it out again here would mean deciding for a second
    # time where a session ends, and `finished_at` -- which is a thing the lifter said rather
    # than something inferred from silence -- lives on the workout, which this never sees.
    # Active rather than overall, on #318's argument: a gap too long to be training is not
    # time the lifter spent, and pricing a prescription against it would call every session
    # ever left open overnight overprescribed.
    def of(sets, turnaround:, active_seconds: nil)
      gaps = paired(sets.select { |set| set[:completed_at] }.sort_by { |set| set[:completed_at] })
      Finding.new(*rest_counts(gaps), longest(gaps), sets.count { |set| !set[:is_completed] },
                  SessionLength.estimate(sets, turnaround:).seconds, active_seconds)
    end

    # How many rests ran over, and how many there were to run over. The denominator is what
    # keeps the numerator readable: twelve out of eighteen and twelve out of a hundred are
    # different sessions, and the bare count cannot tell them apart.
    def rest_counts(gaps)
      [gaps.count { |gap| over?(gap) }, gaps.count { |gap| gap[:prescribed] }]
    end

    # Consecutive completions paired with the set each gap belongs to. The gap after set N is
    # N's rest, so the prescription read is N's and the working time subtracted is N+1's.
    #
    # Gaps above LONG_GAP_SECONDS are left out on Timing's rule: twenty-five minutes is
    # somebody who walked away, and a session logged either side of midnight would otherwise
    # report a fourteen-hour rest as a rest that ran long. Timing already counts those
    # separately and the record already prints the count.
    def paired(done)
      done.each_cons(2).filter_map do |before, after|
        seconds = (after[:completed_at] - before[:completed_at]).to_i
        next unless seconds.positive? && seconds <= Timing::LONG_GAP_SECONDS

        { rest: seconds - SessionLength.working_seconds(after), prescribed: before[:planned_rest_seconds] }
      end
    end

    # Over only where there is a prescription to be over. A set the block said nothing about
    # cannot have taken longer than it was told to, and counting it against this lifter's own
    # median would turn "you rested longer than usual" into "you did it wrong" -- which is a
    # judgement, and #263 settled that judgements are not the app's.
    def over?(gap)
      gap[:prescribed] && gap[:rest] > gap[:prescribed]
    end

    # The longest single rest, and only when it is long enough to be the story. Nil otherwise,
    # because "the longest gap was 2m 10s" on a session of two-minute rests is a sentence that
    # says nothing.
    def longest(gaps)
      worst = gaps.map { |gap| gap[:rest] }.max
      worst && worst >= NOTABLE_GAP_SECONDS ? worst : nil
    end

    # The three facts as a sentence, in the order #409 writes them. Nil where there is nothing
    # to say, so a session lifted as written gets no line at all rather than a line saying
    # everything was fine.
    def sentence(finding)
      return nil unless finding.anything?

      [rests_phrase(finding), gap_phrase(finding), unfinished_phrase(finding)].compact.join(', ')
    end

    # "12 of 18 sets over the prescribed rest" rather than "12 sets over", because twelve out
    # of eighteen and twelve out of a hundred are different sessions and the bare count cannot
    # tell them apart.
    def rests_phrase(finding)
      return nil unless finding.over_rest.positive?

      "#{finding.over_rest} of #{finding.compared} rests ran over the prescription"
    end

    def gap_phrase(finding)
      return nil unless finding.longest_gap

      "one gap of #{Timing.phrase(finding.longest_gap)}"
    end

    def unfinished_phrase(finding)
      return nil unless finding.unfinished.positive?

      "#{finding.unfinished} #{finding.unfinished == 1 ? 'set' : 'sets'} unfinished"
    end
  end
end

