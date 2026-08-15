# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/set_scheme'

describe Tectonic::SetScheme do
  it 'converts the worked squat session to triples climbing to the top' do
    expected = [
      { weight: 150, reps: 3 },
      { weight: 155, reps: 3 },
      { weight: 160, reps: 3 },
      { weight: 165, reps: 3 }
    ]

    assert_equal expected, Tectonic::SetScheme.working_sets(sets: 4, reps: 5, top_weight: 155, preferred_reps: 3)
  end

  it 'sits flat at the top weight when the program does not ascend' do
    sets = Tectonic::SetScheme.working_sets(sets: 4, reps: 5, top_weight: 155, preferred_reps: 3, is_ascending: false)

    assert_equal([165, 165, 165, 165], sets.map { |set| set[:weight] })
  end

  it 'keeps the prescribed reps when the program states no preference' do
    sets = Tectonic::SetScheme.working_sets(sets: 3, reps: 8, top_weight: 105)

    assert_equal([8, 8, 8], sets.map { |set| set[:reps] })
    assert_equal 105, sets.last[:weight]
  end

  it 'leaves accessory rep counts the chart does not cover alone' do
    # Decline paused bench, 3x8 at 105, in a program preferring triples.
    sets = Tectonic::SetScheme.working_sets(sets: 3, reps: 8, top_weight: 105, preferred_reps: 3)

    assert_equal([8, 8, 8], sets.map { |set| set[:reps] })
    assert_equal 105, sets.last[:weight]
  end

  it 'never converts upward into more reps at less weight' do
    sets = Tectonic::SetScheme.working_sets(sets: 3, reps: 3, top_weight: 165, preferred_reps: 5)

    assert_equal([3, 3, 3], sets.map { |set| set[:reps] })
    assert_equal 165, sets.last[:weight]
  end

  it 'converts a top weight between rep counts off the RPE chart' do
    assert_equal 165, Tectonic::SetScheme.convert_weight(155, from_reps: 5, to_reps: 3)
    assert_equal 170, Tectonic::SetScheme.convert_weight(155, from_reps: 5, to_reps: 2)
    assert_equal 155, Tectonic::SetScheme.convert_weight(155, from_reps: 5, to_reps: 5)
  end

  it 'tops out at the working weight for a single set' do
    assert_equal [{ weight: 155, reps: 5 }], Tectonic::SetScheme.working_sets(sets: 1, reps: 5, top_weight: 155)
  end
end