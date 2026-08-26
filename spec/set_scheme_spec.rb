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

  it 'tops out at the working weight for a single set' do
    assert_equal [{ weight: 155, reps: 5 }], Tectonic::SetScheme.working_sets(sets: 1, reps: 5, top_weight: 155)
  end
end

# A 3% step is 3.15 lb at 105 and rounds away entirely on a 5 lb rack, which used to
# produce two identical sets under an ascending heading.
describe 'Tectonic::SetScheme on a lift too light for a percentage step' do
  it 'ascends by one increment a set rather than repeating a load' do
    sets = Tectonic::SetScheme.working_sets(sets: 3, reps: 8, top_weight: 105)

    assert_equal([95, 100, 105], sets.map { |set| set[:weight] })
  end

  it 'reaches the prescribed top weight all the same' do
    [95, 105, 115].each do |top|
      weights = Tectonic::SetScheme.working_sets(sets: 3, reps: 8, top_weight: top).map { |set| set[:weight] }

      assert_equal top, weights.last
      assert_equal weights.uniq, weights
    end
  end

  # The rack decides what is expressible: 3% of 105 is 3.15 lb, which a pair of 1.25s can
  # nearly make and a pair of 2.5s cannot.
  it 'keeps the percentage when the rack has plates fine enough for it' do
    sets = Tectonic::SetScheme.working_sets(sets: 3, reps: 8, top_weight: 105,
                                            loading: Tectonic::Rounding::Loading.by_increment(2.5))

    assert_equal([97.5, 102.5, 105], sets.map { |set| set[:weight] })
  end

  # Nothing above zero can be laid out as a ramp here, and a flat prescription is honest
  # where an invented one is not.
  it 'sits flat when even one increment a set cannot fit above zero' do
    sets = Tectonic::SetScheme.working_sets(sets: 4, reps: 8, top_weight: 10)

    assert_equal([10, 10, 10, 10], sets.map { |set| set[:weight] })
  end
end

# The percentage survives rounding on anything heavy, so no block that already generated
# a sensible ramp is rewritten by this.
describe 'Tectonic::SetScheme on a lift heavy enough for a percentage step' do
  it 'still steps by the percentage' do
    weights = Tectonic::SetScheme.working_sets(sets: 5, reps: 5, top_weight: 405).map { |set| set[:weight] }

    assert_equal [355, 370, 380, 395, 405], weights
  end
end

describe 'Tectonic::SetScheme rep conversion' do
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
end

