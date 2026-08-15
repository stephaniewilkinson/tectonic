# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/warmup'

describe Tectonic::Warmup do
  it 'ramps the worked squat session from the empty bar' do
    expected = [
      { weight: 45, reps: 5 },
      { weight: 95, reps: 5 },
      { weight: 115, reps: 3 },
      { weight: 135, reps: 2 }
    ]

    assert_equal expected, Tectonic::Warmup.ramp(155)
  end

  it 'descends reps as the weight climbs' do
    reps = Tectonic::Warmup.ramp(155).map { |set| set[:reps] }

    assert_equal [5, 5, 3, 2], reps
  end

  it 'skips warmups for anything not on a barbell' do
    assert_empty Tectonic::Warmup.ramp(155, is_barbell: false)
  end

  it 'skips warmups when the working weight is the bar itself' do
    assert_empty Tectonic::Warmup.ramp(45)
  end
end

describe 'Tectonic::Warmup ramp shape' do
  it 'ramps less for lighter lifts' do
    assert_equal 4, Tectonic::Warmup.ramp(155).length
    assert_equal 3, Tectonic::Warmup.ramp(135).length
    assert_equal 2, Tectonic::Warmup.ramp(95).length
  end

  it 'never ramps below the bar, or twice at the same weight' do
    assert_equal [{ weight: 45, reps: 5 }], Tectonic::Warmup.ramp(50)
  end

  it 'rounds every warmup to the nearest five pounds' do
    # 157 is deliberately off the grid: 60% of it is 94.2, 75% is 117.75.
    weights = Tectonic::Warmup.ramp(157).map { |set| set[:weight] }

    assert_equal [45, 95, 120, 135], weights
  end

  it 'starts from whichever bar is being loaded' do
    assert_equal 35, Tectonic::Warmup.ramp(155, bar_weight: 35).first[:weight]
  end
end