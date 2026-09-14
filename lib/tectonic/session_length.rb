# frozen_string_literal: true

require_relative 'measured'

class Tectonic < Roda
  # How long a session will take, before anybody has taken it. #408.
  #
  # A generated deadlift day came out at 29 sets across four loaded movements -- roughly
  # ninety minutes against a one-hour cap -- and nothing flagged it. The lifter found out by
  # running out of time.
  #
  # #263 built the measurement half and it is good: a finished session reports how long it
  # ran, what a typical turnaround was, and where the gaps were. What was missing is the
  # other direction -- a number *before* the session, to compare a budget against.
  #
  # **This became cheap when #281 landed.** The original note said an estimate would have to
  # be derived from observed rest intervals. It no longer does: `program_lifts.rest_seconds`
  # is copied onto every working set as `planned_rest_seconds`, so a prescribed day's length
  # is arithmetic on data already on the rows.
  #
  # ## What is measured and what is assumed
  #
  # The rest between sets is the large term and it is mostly real. Three minutes between
  # heavy singles is three minutes, and it dwarfs the forty seconds the singles take. So the
  # estimate is honest about where each set's rest came from, and says so in the counts it
  # returns rather than folding everything into one number that looks equally solid
  # throughout:
  #
  #   * **prescribed** -- the block said how long to rest. The best case and the one #281
  #     created.
  #   * **measured** -- the block said nothing, so this lifter's own median turnaround on the
  #     movement is used. That is what the rest timer falls back to, and using a different
  #     fallback here would make the page and the timer disagree about the same set.
  #   * **assumed** -- neither exists, because the movement has never been trained. DEFAULT_
  #     REST_SECONDS is the one invented number in this file and a caller that cares can see
  #     how many sets it touched.
  #
  # **The working time is a constant and is declared as one.** #408 says so outright: "no
  # model of how long a set takes to perform beyond a constant". A setup cost plus a few
  # seconds a rep is a better constant than a flat number -- a single and a set of twenty are
  # not the same minute -- but it is still a constant, not a measurement, and nothing here
  # pretends otherwise. It is also the small term: on the session that prompted this issue it
  # is about a fifth of the total.
  #
  # A set held for time knows exactly how long it takes, because that is what the
  # prescription is. It is the one part of the working time that is not a guess.
  #
  # ## What it deliberately does not do
  #
  # It does not decide whether a session is too long. The budget lives on the block, the
  # comparison is arithmetic, and what to do about an overshoot -- cut a movement, cut a set,
  # accept the ninety minutes -- is a coaching decision. The app reports the two numbers and
  # the difference between them.
  module SessionLength
    # The working time of one rep-counted set: a setup cost plus a few seconds a rep. Both
    # are constants, both are declared here, and neither is measured from anything.
    SETUP_SECONDS = 20
    SECONDS_PER_REP = 4
    # The rest used for a set that has neither a prescription nor any history to measure --
    # a movement being trained for the first time. Two minutes is unremarkable for
    # accessory work and will be wrong for a heavy single, which is why the count of sets it
    # touched travels with the answer.
    DEFAULT_REST_SECONDS = 120

    # The estimate and what it rests on. The three counts add up to the number of sets, so a
    # reader can tell "fifty minutes, all of it prescribed" from "fifty minutes, half of it
    # assumed" -- which are the same number and very different claims.
    Estimate = Struct.new(:seconds, :prescribed, :measured, :assumed) do
      def sets = prescribed + measured + assumed

      # Whether anything in here was invented. What a caller says about that is its own
      # business; this only reports that there was something to say.
      def assumed? = assumed.positive?

      def minutes = (seconds / 60.0).round
    end

    module_function

    # How long these sets will take, given a way of asking what this lifter usually takes
    # between sets of a movement.
    #
    # `turnaround` is a callable taking an exercise id and answering seconds or nil, rather
    # than a number or a table, because the caller is the one that knows how to ask cheaply.
    # The session screen already has that lookup and memoises it across a page; passing the
    # numbers in would mean this module deciding how many queries to make on somebody else's
    # behalf.
    def estimate(sets, turnaround:)
      sets.reduce(Estimate.new(0, 0, 0, 0)) { |running, set| add(running, set, turnaround) }
    end

    def add(running, set, turnaround)
      rest, basis = rest_for(set, turnaround)
      Estimate.new(running.seconds + working_seconds(set) + rest,
                   running.prescribed + (basis == :prescribed ? 1 : 0),
                   running.measured + (basis == :measured ? 1 : 0),
                   running.assumed + (basis == :assumed ? 1 : 0))
    end

    # The prescription leads and the measurement is the fallback, which is #281's rule for
    # the rest timer said again here. A timer counting down the block's three minutes while
    # the page above it priced the same set at the lifter's own ninety seconds would be two
    # numbers from one app disagreeing about one set.
    def rest_for(set, turnaround)
      prescribed = set[:planned_rest_seconds]
      return [prescribed, :prescribed] if prescribed

      measured = turnaround.call(set[:exercise_id])
      measured ? [measured, :measured] : [DEFAULT_REST_SECONDS, :assumed]
    end

    # A held position takes as long as it is held, which is the one piece of working time
    # here that is a fact rather than a constant.
    #
    # A per-side count is twice the work, for the reason Volume doubles it (#279): eight
    # each side is sixteen sets of eight seconds, not eight. Getting this wrong halves the
    # estimate for a session of unilateral accessories, which is exactly the kind of session
    # that overruns.
    def working_seconds(set)
      return set[:duration_seconds].to_i if Measured.cast(set[:measure]) == Measured::TIME

      reps = set[:reps].to_i
      reps *= 2 if set[:is_per_side]
      SETUP_SECONDS + (reps * SECONDS_PER_REP)
    end

    # A session against a budget, or nil where there is no budget to be against. The
    # difference is signed: positive is over, which is the direction anybody asking cares
    # about, and a session comfortably inside its budget is worth being able to see too.
    def against(estimate, budget_minutes)
      return nil unless budget_minutes

      { minutes: estimate.minutes, budget: budget_minutes, over: estimate.minutes - budget_minutes }
    end
  end
end

