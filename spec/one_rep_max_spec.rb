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

  # **This used to be a refusal and is now a number, which is the change and not a slip.**
  #
  # The chart ran to five reps and declined anything restating past it -- on the reasoning that
  # "an estimate off work that light is a guess dressed as a number". The instinct was right
  # and the refusal was the wrong expression of it: silently having no number is worse than a
  # number that says how sure it is, and it produced a real dead end, where a movement trained
  # in eights had no max and the page claimed nothing had been lifted.
  #
  # The row runs to ten now. It is one row and an index shift, which the RTS chart is
  # constructed to allow -- RPE 8 at three reps, RPE 9 at four and RPE 10 at five are the same
  # number -- so extending the row is exactly equivalent to storing the full grid and nothing
  # is approximated by doing it.
  it 'reads work the chart used to decline, now that the row reaches it' do
    # Eight reps at the anchor: 73.9%.
    assert_equal 183, Tectonic::OneRepMax.estimate(weight: 135, reps: 8, rpe: 8)
    # Five at a 6 restates to seven: 76.2%.
    assert_equal 177, Tectonic::OneRepMax.estimate(weight: 135, reps: 5, rpe: 6)
  end

  # What it still declines, and these are refusals about the set rather than about the chart:
  # there is no load to take a fraction of, and eleven restated reps is past the row's end.
  it 'declines where there is nothing to read' do
    assert_nil Tectonic::OneRepMax.estimate(weight: 0, reps: 5, rpe: 8)
    assert_nil Tectonic::OneRepMax.estimate(weight: 135, reps: 12, rpe: 8)
  end
end

# The honesty the old refusal was reaching for, kept as a property of the reading rather than as
# an absence. TrainingMax.derived is what acts on it.
describe 'OneRepMax.reading_of' do
  it 'marks how far from a single the set it read was' do
    close = Tectonic::OneRepMax.reading_of({ weight: 155, reps: 5, rpe: 8 })
    far = Tectonic::OneRepMax.reading_of({ weight: 44, reps: 8, rpe: 7 })

    assert close[:confident]
    refute far[:confident]
    assert_equal 9, far[:from_reps], 'eight reps at RPE 7 is as hard as nine at RPE 8'
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

