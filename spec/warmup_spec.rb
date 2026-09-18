# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/warmup'

# Rewritten for #451: the ramp is spaced by how far the top weight is above the bar rather
# than by a table of absolute thresholds, so a 155 gets three rungs where it used to get four.
# Every number below is convention rather than a result -- see the note on Warmup's constants
# -- which is why a lift can overrule the count outright.
describe Tectonic::Warmup do
  it 'ramps the worked squat session from the empty bar' do
    expected = [
      { weight: 45, reps: 5 },
      { weight: 90, reps: 5 },
      { weight: 135, reps: 3 }
    ]

    assert_equal expected, Tectonic::Warmup.ramp(155)
  end

  # Five until the bar is heavy, then three. The 2-rep rung is gone with the taper it belonged
  # to: the lifter's own sessions are the evidence against it, since on 2026-09-10 the planned
  # 112x3 was done for 5 and the 132x2 for 4.
  it 'descends reps as the weight climbs' do
    reps = Tectonic::Warmup.ramp(155).map { |set| set[:reps] }

    assert_equal [5, 5, 3], reps
  end

  it 'skips warmups for anything not on a barbell' do
    assert_empty Tectonic::Warmup.ramp(155, is_barbell: false)
  end

  it 'still racks the empty bar when the working weight is the bar itself' do
    assert_equal [{ weight: 45, reps: 5 }], Tectonic::Warmup.ramp(45)
  end

  it 'always opens with the empty bar, whatever the working weight' do
    opening = [155, 135, 95, 50, 45].map { |top| Tectonic::Warmup.ramp(top).first[:weight] }

    assert_equal [45, 45, 45, 45, 45], opening
  end
end

describe 'Tectonic::Warmup ramp shape' do
  # The ratio rounded, which is the whole rule: 155 is 3.4 times a 45 lb bar and gets three
  # rungs, 95 is 2.1 and gets two.
  it 'ramps less for lighter lifts' do
    assert_equal 3, Tectonic::Warmup.ramp(155).length
    assert_equal 3, Tectonic::Warmup.ramp(135).length
    assert_equal 2, Tectonic::Warmup.ramp(95).length
  end

  # The heavy end, which the old absolute thresholds could not distinguish at all: a 235 is
  # over five times the bar and genuinely wants five stops, where a 155 wants three.
  it 'ramps more for a lift far above the bar' do
    assert_equal 5, Tectonic::Warmup.ramp(235).length
  end

  it 'never ramps below the bar, or twice at the same weight' do
    assert_equal [{ weight: 45, reps: 5 }], Tectonic::Warmup.ramp(50)
  end

  it 'rounds every warmup to the nearest five pounds' do
    # 157 is deliberately off the grid: the rungs land on 89.9 and 137.4 before rounding.
    weights = Tectonic::Warmup.ramp(157).map { |set| set[:weight] }

    assert_equal [45, 90, 135], weights
  end

  it 'starts from whichever bar is being loaded' do
    assert_equal 35, Tectonic::Warmup.ramp(155, bar_weight: 35).first[:weight]
  end

  # The bar decides the ratio, so it decides the ramp -- which the old absolute thresholds
  # could not express at all, having been written as though every rack held a 45. The same
  # 155 is 3.4 times a men's bar and 4.4 times a women's, and wants a rung more on the lighter
  # one because there is further to climb.
  it 'ramps further from a lighter bar to the same top weight' do
    assert_equal 3, Tectonic::Warmup.ramp(155).length
    assert_equal 4, Tectonic::Warmup.ramp(155, bar_weight: 35).length
  end
end

# What a lift says for itself, which is the half #451 asks for because the shape of a ramp is
# coaching convention rather than a result: "this should be a configurable default, not a fixed
# algorithm asserting a right answer".
describe 'a lift that says its own ramp' do
  it 'takes the count it was given rather than the fitted one' do
    assert_equal 2, Tectonic::Warmup.ramp(235, rungs: 2).length
  end

  # The opt-out #451 asks for outright, for "an accessory late in a session following the same
  # pattern". Zero is truthy in Ruby, so the guard tests for it by name -- #321 is what happens
  # when that is forgotten.
  it 'skips the ramp entirely when asked for none' do
    assert_empty Tectonic::Warmup.ramp(235, rungs: 0)
  end

  it 'falls back to the fitted count where the lift has not said' do
    assert_equal Tectonic::Warmup.ramp(235), Tectonic::Warmup.ramp(235, rungs: nil)
  end
end

