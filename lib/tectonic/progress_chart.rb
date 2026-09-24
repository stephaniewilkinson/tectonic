# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'goal'
require_relative 'one_rep_max'
require_relative 'programs'
require_relative 'sets'
require_relative 'training_max'
require_relative 'workouts'

class Tectonic < Roda
  # One lift's progress, as the four things that have to be on the same axis. #434.
  #
  # `set_goal` and `block_progress` made the data complete and #308 left the answer in prose:
  # what each block opened at, the goal, the gap. What was missing is the picture, and the
  # issue is precise about why it matters -- *"a deadlift at 150 in week 3 looks like
  # stagnation as a number and looks correct on a chart where the training max is 188 and the
  # block is accumulation."*
  #
  # ## The series, and which of them is ground truth
  #
  # **Lifted** is the only one that comes from lifting. The heaviest *completed working* set of
  # each session: warmups excluded because a ramp is not an attempt, and incomplete sets
  # excluded because a set written and not done is a plan. Everything else on this chart is
  # something somebody decided.
  #
  # **Training max** is a step, not a slope. It is flat inside a block and moves when a block
  # opens against a new number, which is what actually happens -- and it is read the way
  # `block_progress` reads it, through `TrainingMax.as_of`, so the chart and the tool cannot
  # disagree about the same block.
  #
  # **Goal** is a single point at its own date, which is the only series that lives in the
  # future by definition.
  #
  # **Estimated 1RM** is the series that catches the thing nothing else does. It is derived
  # from the top set and its RPE, so it tracks what the lifter can actually do rather than what
  # the app was told -- and a bench at 97x5 @RPE 7 against a max still set at 118 shows up
  # here as the estimate pulling away from the step line underneath it.
  #
  # ## The projection, and the line it must not cross
  #
  # #308 and #263 are emphatic that nothing here computes "behind schedule": *"pace on a
  # barbell is not linear, a peaking block moves a max in a way a hypertrophy block
  # deliberately does not, and an app dividing pounds by weeks would call a correctly-run
  # offseason a failure every time."*
  #
  # This draws a line from today's max to the goal anyway, and the two are reconcilable
  # because of what the line is *called* and what it is not allowed to do. It is not a
  # prediction and not a verdict: it is where the number would sit if it moved evenly, drawn
  # so a lifter can see the distance between two things and decide for themselves. The app
  # draws it, says plainly what it is, and never colours it as pass or fail -- no red, no
  # green, no "behind". That is the same split #263 settled, with the app doing the
  # representing.
  #
  # It steps at block boundaries rather than sloping, and that is the more honest shape
  # besides being the one #434 asks for: a training max in this app moves when a block opens
  # and at no other time, so a smooth line would draw a quantity that does not exist.
  module ProgressChart
    # What the view draws and what the table beside it reads. Names are the series labels, so
    # they are written once here rather than in the template and the table separately.
    LIFTED = 'Heaviest set'
    ESTIMATED = 'Estimated 1RM'
    TRAINING_MAX = 'Training max'
    GOAL = 'Goal'
    PROJECTION = 'Even pace to goal'

    module_function

    # Every series for one movement, in drawing order, as name => { Date => pounds }.
    #
    # Empty series are dropped rather than sent as empty arrays: a movement with no goal should
    # have no goal entry in the legend, and a legend naming a line that is not there is worse
    # than a smaller legend.
    #
    # **Nothing at all without a working set to draw**, which is the whole thing rather than
    # one series. Everything here except the heaviest-set line is something somebody decided --
    # a max they stated, a goal they typed, a pace computed from the two -- and a chart of
    # decisions with no evidence on it is not progress, it is a plan drawn as though it had
    # happened.
    #
    # It took a spec to find this. A movement with nothing but warmups logged still has a
    # training max, because the derived one is estimated from whatever is there, so the guard
    # that used to be "are there any points" let through a chart whose single line was a number
    # nobody had lifted for. The page drew no chart before #434 and was right about that.
    #
    # The history and the max are taken from the caller where it has them, which the exercise
    # page does (#596). It used to read this movement's whole history five times in one
    # request -- once here, once in each `TrainingMax.for`, once per block for the step line.
    # The goal is still looked up here; it is one row by key. Read once, every figure on
    # the page is also computed from the same rows: five reads were five moments, and a set
    # completed between two of them could put the chart and the headline in disagreement.
    # Absent, each is read here, which is what a caller asking for the chart alone wants.
    def of(account_id:, exercise:, today: Date.today, lifted: exercise.lifted_sets(account_id, today),
           max: TrainingMax.for(account_id:, exercise:, on: today, lifted:))
      heaviest = heaviest(lifted)
      return {} if heaviest.empty?

      goal = Goal.for(account_id:, exercise_id: exercise.id)

      { LIFTED => heaviest, ESTIMATED => estimated(lifted),
        TRAINING_MAX => training_max(account_id, exercise, today, lifted, max),
        GOAL => goal_point(goal), PROJECTION => projection(account_id, max, goal, today) }
        .reject { |_name, points| points.empty? }
    end

    # The heaviest working set of each session. The ground truth line, and the only one here
    # that is a measurement rather than a decision.
    def heaviest(sets)
      sets.reject { |set| set[:is_warmup] }
          .group_by { |set| set[:date].to_date }
          .filter_map { |day, rows| [day, pounds(rows.filter_map { |set| set[:weight] }.max)] }
          .to_h.compact
    end

    # What each session implies the max was, which is the line that moves when strength does
    # rather than when somebody remembers to restate a number.
    #
    # Warmups are out of this one too, which took a spec to notice. The first version left them
    # in on the grounds that `OneRepMax` reads a set at its rating and a submaximal rung cannot
    # win -- true whenever there are working sets, and wrong in the one case that matters: a
    # movement with nothing but warmups logged would draw a chart consisting of an estimate
    # taken off a warmup. #211 settled what that number is worth. A ramp rung is submaximal by
    # definition, so an estimate from one is not an estimate of anything, and the page goes
    # back to drawing no chart at all -- which is what it did before #434 and was right about.
    def estimated(sets)
      sets.reject { |set| set[:is_warmup] }
          .group_by { |set| set[:date].to_date }
          .filter_map { |day, rows| [day, pounds(OneRepMax.best_of(rows)&.round)] }
          .to_h.compact
    end

    # The step line: what each block was generated against, plus where the number stands today.
    #
    # `TrainingMax.as_of` rather than `for`, which is the distinction `block_progress` exists
    # to respect -- `for` has no history to consult on the stated branch, so a lifter who has
    # since restated 315 as 325 would be told every block they ever ran opened at 325.
    #
    # Today's point is added so the line reaches the right-hand edge rather than stopping at
    # the last block that happened to start, which on a block three weeks in would leave the
    # step line ending well short of the sets drawn beside it.
    #
    # Every block's derived max is read off the history already in hand, which is what stopped
    # a lifter twelve blocks in paying twelve reads of their whole history for this one line.
    def training_max(account_id, exercise, today, lifted, here)
      opened = Program.where(account_id:).order(:start_date).select_map(:start_date)
                      .uniq.select { |date| date <= today }
                      .to_h { |date| [date, TrainingMax.as_of(account_id:, exercise:, on: date, lifted:)&.pounds] }
      opened.merge(today => here&.pounds).compact
    end

    def goal_point(goal)
      return {} unless goal&.by_date && goal.pounds

      { goal.by_date => goal.pounds }
    end

    # Where the number would sit if it moved evenly from here to the goal. Not a prediction.
    #
    # Nothing at all without both ends: no goal, no deadline, or no max to start from means
    # there is no line to draw, and inventing one of the ends to get a line would be the app
    # deciding something. A goal whose date has already passed draws nothing either -- the
    # distance to it is still real and `block_progress` reports it, but a pace line that runs
    # backwards is a graph nobody can read.
    def projection(account_id, max, goal, today)
      return {} unless pace_drawable?(max, goal, today)

      steps = [today, *future_blocks(account_id, today, goal.by_date), goal.by_date].uniq.sort
      span = (goal.by_date - today).to_f
      steps.to_h { |date| [date, paced(max.pounds, goal.pounds, (date - today) / span)] }
    end

    # Both ends, and a deadline that has not gone by. Inventing either end to get a line drawn
    # would be the app deciding something, and a pace line running backwards out of a goal
    # whose date has passed is a graph nobody can read -- the distance to it is still real and
    # `block_progress` still reports it in words.
    def pace_drawable?(max, goal, today)
      return false unless max&.pounds && goal&.by_date && goal.pounds

      goal.by_date > today
    end

    # The blocks between here and the deadline, which is where the line steps. A training max
    # in this app moves when a block opens and at no other time, so the steps are the shape of
    # the thing rather than a decoration on it.
    def future_blocks(account_id, today, deadline)
      Program.where(account_id:).order(:start_date).select_map(:start_date)
             .select { |date| date > today && date < deadline }.uniq
    end

    def paced(from, to, fraction)
      pounds((from + ((to - from) * fraction)).round)
    end

    # A weight as a chart wants it, or nothing.
    #
    # The guard is the whole of it and it is not defensive padding: `Plates.numeric` reaches
    # for `denominator` and raises on nil, and nil is a state both of the measured series reach
    # honestly. A bodyweight movement stores no weight at all, so `max` over a day of press-ups
    # is nil; a session nobody rated and that `OneRepMax` therefore declines to read gives nil
    # too. Neither is an error -- they are days with nothing to plot -- and `compact` drops
    # them so the line has a gap rather than a zero, which is a weight nobody lifted.
    def pounds(value)
      value && Plates.numeric(value)
    end
  end
end

