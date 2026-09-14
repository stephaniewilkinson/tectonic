# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/progress_chart'
require 'securerandom'

# One lift's progress, as the four things that have to be on the same axis. #434.
#
# `set_goal` and `block_progress` made the data complete and #308 left the answer in prose.
# What was missing is the picture, and the issue says why it matters: a deadlift at 150 in week
# 3 looks like stagnation as a number and looks correct on a chart where the training max is
# 188 and the block is accumulation.
#
# What is asserted here is which series exist and what they are made of. What Chart.js paints
# from them is the library's business; the rendered page is specced in exercise_chart_spec.rb.
module ProgressSeries
  TODAY = Date.new(2026, 9, 14)

  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')

  def a_lift(account_id)
    Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
  end

  # No rating on a warmup, which the database refuses outright (#211: RPE is reps in reserve,
  # and a ramp rung is submaximal by definition). A first draft defaulted every set to RPE 8
  # and the check constraint caught it -- which is the constraint doing exactly its job.
  def log(account_id, exercise, weight:, on:, **shape)
    workout_id = DB[:workouts].where(account_id:, date: on).get(:id) ||
                 DB[:workouts].insert(account_id:, date: on)
    warmup = shape.fetch(:is_warmup, false)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, is_barbell: true,
                     reps: shape.fetch(:reps, 5), rpe: warmup ? nil : shape.fetch(:rpe, 8),
                     is_warmup: warmup, is_completed: shape.fetch(:is_completed, true))
  end

  def a_block(account_id, on:)
    Tectonic::Program.create(account_id:, name: "Block #{SecureRandom.hex(4)}", start_date: on, is_ascending: true)
  end

  # Through TrainingMax.replace rather than a raw insert, which is the app's own write path and
  # is the reason the statement log stays in step with the current row. A first draft inserted
  # straight into account_training_maxes, invented a `set_at` column it does not have, and
  # would have left every block reporting a max with no statement behind it even if it had
  # guessed the name right.
  #
  # `stated_at` is then backdated where a test needs the statement to predate a block, because
  # `TrainingMax.as_of` reads the log by date and a statement made today says nothing about
  # what a block in March opened at.
  def state_max(account_id, exercise, pounds, on: nil)
    Tectonic::TrainingMax.replace(account_id, exercise.id, pounds)
    return unless on

    DB[:account_training_max_statements].where(account_id:, exercise_id: exercise.id).update(stated_at: on)
    DB[:account_training_maxes].where(account_id:, exercise_id: exercise.id).update(stated_at: on)
  end

  def set_goal(account_id, exercise, pounds, by:)
    DB[:account_goals].insert(account_id:, exercise_id: exercise.id, pounds:, by_date: by, set_at: ProgressSeries::TODAY)
  end

  def series(account_id, exercise) = Tectonic::ProgressChart.of(account_id:, exercise:, today: TODAY)

  # A lift with something lifted, a max to start from and a goal to run to -- the three things
  # a pace line needs before there is one to draw.
  def a_lift_aiming_at(account_id, pounds, by:, from: 200)
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    state_max(account_id, lift, from)
    set_goal(account_id, lift, pounds, by:)
    lift
  end
end

# The only series that comes from lifting rather than from planning, and the one everything
# else on the chart is measured against.
describe 'the heaviest set of each session' do
  include ProgressSeries

  it 'is one point per session at that session\'s heaviest working set' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    log(account_id, lift, weight: 185, on: Date.new(2026, 3, 2))
    log(account_id, lift, weight: 155, on: Date.new(2026, 3, 9))

    assert_equal({ Date.new(2026, 3, 2) => 185, Date.new(2026, 3, 9) => 155 },
                 series(account_id, lift)[Tectonic::ProgressChart::LIFTED])
  end

  # A ramp is not an attempt. A warmup heavier than the work would otherwise draw the session
  # as the best of the day, which is the opposite of what happened in it.
  it 'leaves warmups out even when one is heavier than the work' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 155, on: Date.new(2026, 3, 9))
    log(account_id, lift, weight: 225, on: Date.new(2026, 3, 9), is_warmup: true)

    assert_equal({ Date.new(2026, 3, 9) => 155 }, series(account_id, lift)[Tectonic::ProgressChart::LIFTED])
  end
end

describe 'a session with work still on the sheet' do
  include ProgressSeries

  # A set written and not done is a plan, and this is the series that is not about plans.
  it 'leaves out a set that was written but never lifted' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 155, on: Date.new(2026, 3, 9))
    log(account_id, lift, weight: 225, on: Date.new(2026, 3, 9), is_completed: false)

    assert_equal({ Date.new(2026, 3, 9) => 155 }, series(account_id, lift)[Tectonic::ProgressChart::LIFTED])
  end
end

# The series that catches what nothing else does: what the sessions imply, against what the app
# was told. #434's own example is a bench at 97x5 @RPE 7 against a max still set at 118.
describe 'the estimated max each session' do
  include ProgressSeries

  it 'is derived from the top set and its rating, so it can sit above a stale training max' do
    account_id = an_account
    lift = a_lift(account_id)
    state_max(account_id, lift, 118)
    log(account_id, lift, weight: 100, on: Date.new(2026, 3, 2), reps: 5, rpe: 8)

    estimated = series(account_id, lift)[Tectonic::ProgressChart::ESTIMATED][Date.new(2026, 3, 2)]

    assert_operator estimated, :>, 118, 'the whole point is that this can exceed the stated max'
  end

  # **#434's own example is a set this app declines to read**, and that is worth a spec rather
  # than a surprise. The issue offers "a bench at 97x5 @RPE 7 against a max still set at 118"
  # as the case this series exists to catch. `OneRepMax` restates a rated set as the RPE-8 set
  # of equal difficulty -- five reps at 7 is six reps at 8 -- and `SetScheme::RPE8_PERCENTS`
  # stops at five, because "an estimate off work that light is a guess dressed as a number".
  #
  # So that session contributes no point and the line has a gap there. That is the honest
  # behaviour and it is not something this chart should quietly work around: extending the
  # chart is a change to the coaching model, not to a graph. Recorded here so the next person
  # reading #434 finds out from a test rather than from an empty stretch of line.
  it 'declines to read a set too easy for the chart to cover, leaving a gap' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2), reps: 5, rpe: 8)
    log(account_id, lift, weight: 97, on: Date.new(2026, 3, 9), reps: 5, rpe: 7)

    assert_equal [Date.new(2026, 3, 2)], series(account_id, lift)[Tectonic::ProgressChart::ESTIMATED].keys
  end

  # A ramp rung is submaximal by definition, so an estimate taken from one is not an estimate
  # of anything (#211). Leaving them in is what made a warmup-only movement draw a chart.
  it 'leaves warmups out' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 9), is_warmup: true)

    assert_equal [Date.new(2026, 3, 2)], series(account_id, lift)[Tectonic::ProgressChart::ESTIMATED].keys
  end
end

# Flat inside a block and moving when one opens, which is what actually happens to the number.
describe 'the training max' do
  include ProgressSeries

  it 'has a point at each block that opened and one for where it stands today' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    a_block(account_id, on: Date.new(2026, 3, 1))
    state_max(account_id, lift, 200, on: Date.new(2026, 2, 1))

    points = series(account_id, lift)[Tectonic::ProgressChart::TRAINING_MAX]

    assert_includes points.keys, Date.new(2026, 3, 1)
    assert_includes points.keys, ProgressSeries::TODAY
  end

  # A block that has not started cannot have opened at anything, and a step drawn at its start
  # date would be the app claiming to know a number nobody has stated yet.
  it 'says nothing about a block that has not started' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    a_block(account_id, on: ProgressSeries::TODAY + 30)

    refute_includes series(account_id, lift)[Tectonic::ProgressChart::TRAINING_MAX].keys,
                    ProgressSeries::TODAY + 30
  end
end

describe 'the goal' do
  include ProgressSeries

  it 'is one point, at its own date' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    set_goal(account_id, lift, 250, by: Date.new(2027, 3, 1))

    assert_equal({ Date.new(2027, 3, 1) => 250 }, series(account_id, lift)[Tectonic::ProgressChart::GOAL])
  end

  # A legend naming a line that is not there is worse than a smaller legend.
  it 'is absent entirely where none is set' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))

    refute_includes series(account_id, lift).keys, Tectonic::ProgressChart::GOAL
  end
end

# #308 and #263 are emphatic that nothing computes "behind schedule". This draws a line anyway,
# and the two are reconcilable because of what it is called and what it is not allowed to do:
# it is where the number would sit if it moved evenly, and it is never coloured as pass or fail.
describe 'the pace line' do
  include ProgressSeries

  it 'runs from where the max stands today to the goal at its date' do
    account_id = an_account
    lift = a_lift_aiming_at(account_id, 250, by: ProgressSeries::TODAY + 180)

    points = series(account_id, lift)[Tectonic::ProgressChart::PROJECTION]

    assert_equal 200, points[ProgressSeries::TODAY]
    assert_equal 250, points[ProgressSeries::TODAY + 180]
  end

  # A training max in this app moves when a block opens and at no other time, so the steps are
  # the shape of the quantity rather than a decoration on it.
  it 'steps where a planned block opens' do
    account_id = an_account
    lift = a_lift_aiming_at(account_id, 250, by: ProgressSeries::TODAY + 180)
    a_block(account_id, on: ProgressSeries::TODAY + 90)

    points = series(account_id, lift)[Tectonic::ProgressChart::PROJECTION]

    assert_equal 225, points[ProgressSeries::TODAY + 90], 'half way in time should be half way in pounds'
  end
end

# Inventing either end to get a line drawn would be the app deciding something, so each missing
# end is its own case.
describe 'a pace line with an end missing' do
  include ProgressSeries

  it 'is not drawn without a goal to run to' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    state_max(account_id, lift, 200)

    refute_includes series(account_id, lift).keys, Tectonic::ProgressChart::PROJECTION
  end

  it 'is not drawn without a deadline' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 135, on: Date.new(2026, 3, 2))
    state_max(account_id, lift, 200)
    set_goal(account_id, lift, 250, by: nil)

    refute_includes series(account_id, lift).keys, Tectonic::ProgressChart::PROJECTION
  end

  # A pace line running backwards out of a goal whose date has passed is a graph nobody can
  # read. The distance to it is still real and block_progress still reports it in words.
  it 'is not drawn once the deadline has gone by' do
    account_id = an_account
    lift = a_lift_aiming_at(account_id, 250, by: ProgressSeries::TODAY - 1)

    refute_includes series(account_id, lift).keys, Tectonic::ProgressChart::PROJECTION
  end
end

# Everything except the heaviest-set line is something somebody decided. A chart of decisions
# with no evidence on it is not progress, it is a plan drawn as though it had happened.
describe 'a movement with nothing lifted' do
  include ProgressSeries

  it 'has no series at all, even where a max and a goal are set' do
    account_id = an_account
    lift = a_lift(account_id)
    state_max(account_id, lift, 200)
    set_goal(account_id, lift, 250, by: ProgressSeries::TODAY + 90)

    assert_empty series(account_id, lift)
  end

  # The case that found the rule: a derived training max is estimated from whatever is there,
  # warmups included, so this used to draw a chart whose only line was a number nobody had
  # lifted for.
  it 'has no series where only warmups were logged' do
    account_id = an_account
    lift = a_lift(account_id)
    log(account_id, lift, weight: 45, on: Date.new(2026, 3, 2), is_warmup: true)

    assert_empty series(account_id, lift)
  end
end

# A library movement is shared and the training on it is not.
describe 'a movement two accounts both train' do
  include ProgressSeries

  it 'charts only the account that asked' do
    mine = an_account
    theirs = an_account
    lift = Tectonic::Exercise.create(account_id: nil, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    log(mine, lift, weight: 135, on: Date.new(2026, 3, 2))
    log(theirs, lift, weight: 405, on: Date.new(2026, 3, 2))

    assert_equal({ Date.new(2026, 3, 2) => 135 }, series(mine, lift)[Tectonic::ProgressChart::LIFTED])
  ensure
    Tectonic::WorkoutSet.where(exercise_id: lift&.id).delete
    Tectonic::Exercise.where(id: lift&.id).delete
  end
end

