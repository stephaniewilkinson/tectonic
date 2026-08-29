# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/one_rep_max'
require_relative '../lib/tectonic/program_generator'
require 'securerandom'

# What rating an unrated set is read at. #294.
#
# `ANCHOR_RPE` was the only fallback, and its own note gives the reason: "the programs this
# app generates write their top sets to land near an 8". True of a `linear` lift, whose top
# weight is stepped to land there. False of a `percent` lift, whose intensity is authored on
# the row -- a top set at 70% of max is nowhere near an 8, and reading it as one estimates a
# max off a set that was deliberately easy.
#
# Since #265 the generator copies the prescription's own answer onto the set, so the better
# assumption is sitting on the row. The precedence under test is: what the lifter said, else
# what the block asked, else the anchor.
describe 'the rating a set is read at' do
  it 'is what the lifter said, when they said' do
    assert_equal 9, Tectonic::OneRepMax.rating_for(9, 6)
  end

  # The block's own answer beats the anchor, because it is a statement about this set rather
  # than an assumption about sets in general.
  it 'is what the block asked for, when the lifter did not say' do
    assert_equal 6, Tectonic::OneRepMax.rating_for(nil, 6)
  end

  # Every set logged by hand, and every one written before #265, has neither.
  it 'is the anchor when there is neither' do
    assert_equal Tectonic::OneRepMax::ANCHOR_RPE, Tectonic::OneRepMax.rating_for(nil, nil)
  end

  # A rating of the same value as the target is not a special case, but it is the one where
  # getting the precedence backwards would be invisible, so it is worth pinning.
  it 'is unchanged when the two agree' do
    assert_equal 8, Tectonic::OneRepMax.rating_for(8, 8)
  end
end

# The arithmetic the precedence feeds. A set is restated as the RPE-8 set of equal
# difficulty, so a *lower* rating means more reps in reserve and a higher implied max:
# three reps at 200 read as an 8 uses the chart's 3-rep row (86.3%), and read as a 6 it
# restates to a 5-rep row (81.1%) and comes out higher.
describe 'estimating from a set the block priced easy' do
  it 'reads it at the target rather than at the anchor' do
    at_target = Tectonic::OneRepMax.estimate(weight: 200, reps: 3, planned_rpe: 6)
    at_anchor = Tectonic::OneRepMax.estimate(weight: 200, reps: 3)

    assert_operator at_target, :>, at_anchor,
                    'a set asked for at RPE 6 implies a higher max than the same set read as an 8'
  end

  it 'still prefers a rating the lifter gave over the target' do
    rated = Tectonic::OneRepMax.estimate(weight: 200, reps: 3, rpe: 9, planned_rpe: 6)

    assert_equal Tectonic::OneRepMax.estimate(weight: 200, reps: 3, rpe: 9), rated
    refute_equal Tectonic::OneRepMax.estimate(weight: 200, reps: 3, planned_rpe: 6), rated
  end

  # The chart runs 1 to 5 reps, and a rating below the anchor restates a set to *more* reps
  # than it was taken for. Five at RPE 6 restates to a seven-rep set, which the chart does
  # not cover -- so it declines rather than inventing a row, which is the same refusal
  # `estimate` already made for a set of 8.
  it 'declines where the target restates the set off the end of the chart' do
    assert_nil Tectonic::OneRepMax.estimate(weight: 200, reps: 5, planned_rpe: 6)
  end
end

# The end-to-end case #294 exists for: a percentage block whose own prescription used to
# inflate the max it is generated against.
describe 'a percentage lift generated, lifted as written, and read back' do
  before do
    @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    @exercise = Tectonic::Exercise.create(name: "Lift #{SecureRandom.hex(4)}", account_id: @account_id,
                                          is_barbell: true)
  end

  # A set written at a target of 6 and completed without a rating. Before #294 it was read
  # as an 8 -- an easy set counted as a hard one -- and the estimate came out high.
  def lift_a_set_targeted_at(target)
    workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: @exercise.id, weight: 200, reps: 3,
                     is_warmup: false, is_completed: true, is_barbell: true, planned_rpe: target)
    @exercise.estimated_max(account_id: @account_id)
  end

  it 'reads the completed set at the effort the block asked for' do
    assert_equal Tectonic::OneRepMax.estimate(weight: 200, reps: 3, planned_rpe: 6),
                 lift_a_set_targeted_at(6)
  end

  # The set the anchor was written for: a top set the programme meant to land near an 8.
  # Reading it at its target and reading it at the anchor are the same answer, which is why
  # this change moves nothing for a linear block.
  it 'is unchanged for a set the block asked for at the anchor' do
    assert_equal Tectonic::OneRepMax.estimate(weight: 200, reps: 3),
                 lift_a_set_targeted_at(Tectonic::OneRepMax::ANCHOR_RPE)
  end
end

