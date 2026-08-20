# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/one_rep_max'

describe 'OneRepMax.estimate' do
  it 'reads a set at the chart anchor straight off the RPE-8 percentages' do
    assert_equal 191, Tectonic::OneRepMax.estimate(weight: 155, reps: 5, rpe: 8) # 155 / 0.811
    assert_equal 180, Tectonic::OneRepMax.estimate(weight: 155, reps: 3, rpe: 8) # 155 / 0.863
  end

  it 'reads an unrated set as an 8, which is what the programs are written at' do
    assert_equal Tectonic::OneRepMax.estimate(weight: 155, reps: 5, rpe: 8),
                 Tectonic::OneRepMax.estimate(weight: 155, reps: 5)
  end

  it 'trades a rep left in reserve for a rep on the bar' do
    # Three at a 10 is as hard as one at an 8, so it reads off the same row: 92.4%.
    assert_equal 168, Tectonic::OneRepMax.estimate(weight: 155, reps: 3, rpe: 10)
    # Three at a 6 restates to five at an 8, the easiest row the chart carries.
    assert_equal 191, Tectonic::OneRepMax.estimate(weight: 155, reps: 3, rpe: 6)
  end

  it 'takes a single at RPE 10 as the max itself rather than a fraction of one' do
    assert_equal 225, Tectonic::OneRepMax.estimate(weight: 225, reps: 1, rpe: 10)
  end

  it 'declines to estimate from work the chart cannot read' do
    assert_nil Tectonic::OneRepMax.estimate(weight: 135, reps: 8, rpe: 8)
    assert_nil Tectonic::OneRepMax.estimate(weight: 135, reps: 5, rpe: 6)
    assert_nil Tectonic::OneRepMax.estimate(weight: 0, reps: 5, rpe: 8)
  end
end

describe 'OneRepMax.best_of' do
  it 'takes the most that has been demonstrated, not the most recent' do
    sets = [{ weight: 155, reps: 5, rpe: 8 }, { weight: 185, reps: 2, rpe: 9 }, { weight: 95, reps: 5, rpe: 6 }]
    assert_equal 200, Tectonic::OneRepMax.best_of(sets) # two at a 9 restates to one at an 8: 92.4%
  end

  it 'is nil when nothing in the group can be read' do
    assert_nil Tectonic::OneRepMax.best_of([{ weight: 135, reps: 12, rpe: 9 }])
    assert_nil Tectonic::OneRepMax.best_of([])
  end
end

