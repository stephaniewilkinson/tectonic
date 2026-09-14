# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/set_scheme'
require_relative '../lib/tectonic/one_rep_max'

# The RPE row reaches ten reps, and not one prescription moved.
#
# That is the whole bargain of this change and the only part of it that could break somebody's
# training, so it is asserted first and hardest.
#
# The row is the RPE 8 line of the standard chart, and one row is the whole chart: the RTS
# table is built as a single shifted sequence, so RPE 8 at three reps, RPE 9 at four and RPE 10
# at five are the same number. Reading a set by shifting `reps + 8 - rating` is therefore
# exactly equivalent to storing the full grid, and extending the row approximates nothing.
describe 'what extending the row must not touch' do
  # `target_reps` used to refuse a conversion by asking whether the chart covered the rep count,
  # so a lift written at eight reps was exempt from conversion *because eight was off the end*.
  # Extending the chart would have silently removed that exemption and started rewriting every
  # high-rep accessory in a block with a preferred rep count -- a change to somebody's
  # programme arrived at as a side effect of fixing an estimate.
  #
  # CONVERTIBLE is that exemption made a rule instead of an accident. It is also the only thing
  # keeping rep schemes a per-lift decision rather than one driven globally from a single
  # setting.
  it 'leaves a set of eight a set of eight, however far the chart now reaches' do
    assert_equal 8, Tectonic::SetScheme.target_reps(8, 5)
    assert_equal 10, Tectonic::SetScheme.target_reps(10, 3)
  end

  it 'goes on converting between the rep counts it always converted between' do
    assert_equal 5, Tectonic::SetScheme.target_reps(5, 5)
    assert_equal 3, Tectonic::SetScheme.target_reps(5, 3)
  end

  # The weight half of the same guarantee. A prescription at eight reps keeps its weight
  # exactly, because there is no conversion for it to go through.
  it 'leaves the weight of a high-rep prescription alone' do
    assert_equal 100, Tectonic::SetScheme.convert_weight(100, from_reps: 8, to_reps: 5)
    assert_equal 100, Tectonic::SetScheme.convert_weight(100, from_reps: 5, to_reps: 8)
  end

  # And the conversion that did exist still gives the number it always gave: 5 reps at 81.1% to
  # 3 reps at 86.3% is the example in convert_weight's own comment.
  it 'still converts a five to a three the way it always did' do
    assert_equal 165, Tectonic::SetScheme.convert_weight(155, from_reps: 5, to_reps: 3)
  end
end

# The reach itself, at the two ends and at the row the split squat lands on.
describe 'how far the estimate now reads' do
  it 'reads a set of ten at the anchor' do
    assert_equal 199, Tectonic::OneRepMax.estimate(weight: 135, reps: 10, rpe: 8)
  end

  # The reported case: 44 lb for eight at RPE 7 is as hard as nine at RPE 8, which is 70.7%.
  it 'reads the split squat that started all this' do
    assert_equal 62, Tectonic::OneRepMax.estimate(weight: 44, reps: 8, rpe: 7)
  end

  # Past ten there is still no row, and it still declines rather than extrapolating.
  it 'stops somewhere, and says so by declining' do
    assert_nil Tectonic::OneRepMax.estimate(weight: 135, reps: 11, rpe: 8)
  end
end

# The honesty the old refusal was carrying, kept as a property of the reading.
#
# **The boundary is six.** #461.
#
# It shipped at five, and five had one real argument: it is where the table used to stop, so
# nothing that could set a max before changed and nothing new started. That made the extension
# provably free. It is not a reason on its own, though -- it makes the boundary an artefact of
# how long the table used to be rather than a claim about how far from a single a set may sit
# and still price a block.
#
# Six is the ordinary claim. A set of six at RPE 8 is two reps from failure, well inside the
# range the chart was built from, and at five a lifter training fives at RPE 7 -- which
# restates to six -- never got a derived max at all.
#
# Checked against production rather than argued: two derived maxes move, both on movements
# with no stated max, Front Squat 105 to 123 and Decline Bench 126 to 130.
describe 'which readings may set a number by themselves' do
  def reading(**set) = Tectonic::OneRepMax.reading_of(set)

  it 'trusts a set close enough to a single' do
    assert reading(weight: 155, reps: 5, rpe: 8)[:confident]
    assert reading(weight: 155, reps: 3, rpe: 6)[:confident]
  end

  # The set of fives at RPE 7 that six exists to admit: six restated reps, which is what a
  # conservative lifter's ordinary working set comes out at.
  it 'trusts a set of fives taken two reps from failure' do
    assert reading(weight: 155, reps: 5, rpe: 7)[:confident]
    assert reading(weight: 155, reps: 6, rpe: 8)[:confident]
  end

  it 'does not trust one further out than that' do
    refute reading(weight: 155, reps: 7, rpe: 8)[:confident]
    refute reading(weight: 44, reps: 8, rpe: 7)[:confident]
  end

  # The boundary said as a whole range, so moving it is a visible edit here rather than a
  # silent change of behaviour somewhere else.
  it 'trusts everything up to six restated reps and nothing past it' do
    (1..6).each { |reps| assert reading(weight: 155, reps:, rpe: 8)[:confident] }
    (7..10).each { |reps| refute reading(weight: 155, reps:, rpe: 8)[:confident] }
  end

  # The best reading and the best trustworthy reading are different questions, and both are
  # wanted at once: the chart draws the first and the training max takes the second.
  it 'tells the best estimate apart from the best one allowed to stand alone' do
    sets = [{ weight: 44, reps: 8, rpe: 7 }, { weight: 40, reps: 3, rpe: 8 }]

    assert_equal 62, Tectonic::OneRepMax.best_of(sets)
    assert_equal 46, Tectonic::OneRepMax.best_confident_reading(sets)[:pounds]
  end

  it 'has no trustworthy reading at all where every set is a long way out' do
    assert_nil Tectonic::OneRepMax.best_confident_reading([{ weight: 44, reps: 8, rpe: 7 }])
  end
end

