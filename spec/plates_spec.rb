# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/plates'

describe Tectonic::Plates do
  it 'loads every weight from the worked squat session' do
    expected = {
      45 => '—',
      95 => '1×25',
      115 => '1×25 1×10',
      135 => '1×45',
      150 => '1×45 1×5 1×2.5',
      155 => '1×45 1×10',
      160 => '1×45 1×10 1×2.5',
      165 => '1×45 1×10 1×5'
    }
    loaded = expected.keys.to_h { |weight| [weight, Tectonic::Plates.label(Tectonic::Plates.per_side(weight))] }

    assert_equal expected, loaded
  end

  it 'returns nothing to load for a bare bar' do
    assert_empty Tectonic::Plates.per_side(45)
  end

  it 'returns nil below the weight of the bar' do
    assert_nil Tectonic::Plates.per_side(35)
  end

  it 'returns nil for a weight no combination of plates reaches' do
    assert_nil Tectonic::Plates.per_side(47)
  end
end

# What to say when per_side has to answer nil. A weight the rack cannot make is the
# moment plate math is worth the most, and nil is the one answer that cannot be shown.
describe 'Tectonic::Plates.closest' do
  it 'answers with the weight itself when the rack can make it' do
    assert_equal [135, [[45, 1]]], Tectonic::Plates.closest(135)
  end

  # 124 is 39.5 a side. 40 is a 25, a 10 and a 5, half a pound out; 37.5 is two pounds
  # out the other way, so the nearest is 125 rather than the largest weight underneath.
  it 'reaches past a weight the rack cannot make to the nearest it can' do
    weight, breakdown = Tectonic::Plates.closest(124)

    assert_equal 125, weight
    assert_equal '1×25 1×10 1×5', Tectonic::Plates.label(breakdown)
  end

  it 'gives a bare bar back as the nearest thing to a weight just above it' do
    assert_equal [45, []], Tectonic::Plates.closest(47)
  end

  it 'has nothing to offer below the weight of the bar' do
    assert_nil Tectonic::Plates.closest(35)
  end
end

describe 'Tectonic::Plates.closest when the two nearest weights are equally far' do
  # A rack of one pair of 45s and two pairs of 10s makes 85 and 135 and nothing between,
  # so a prescribed 110 is 25 lb from either. The lighter one wins: overshooting adds
  # work nobody asked for and can turn a planned single into a miss, where undershooting
  # the same distance costs a little stimulus and nothing else.
  it 'breaks the tie towards the lighter bar' do
    assert_equal [85, [[10, 2]]], Tectonic::Plates.closest(110, inventory: { 45 => 1, 10 => 2 })
  end

  # A rack given as a bare list owns as many of each as a weight needs, so the search
  # has to be bounded by the target rather than by a pair count that is infinite.
  it 'terminates against a rack with no pair counts on it' do
    assert_equal [125, [[20, 2]]], Tectonic::Plates.closest(126, inventory: [45, 35, 20])
  end
end

describe 'Tectonic::Plates on a rack other than the default' do
  it 'uses a 35 when the rack has them' do
    assert_equal [[35, 1]], Tectonic::Plates.per_side(115, inventory: [45, 35, 25, 10, 5, 2.5])
  end

  it 'backtracks past a heavier plate that leaves an unloadable remainder' do
    # Greedy takes the 35 and strands 5 lb; the loadable answer is two 20s.
    assert_equal [[20, 2]], Tectonic::Plates.per_side(125, inventory: [45, 35, 20])
  end

  it 'loads against a lighter bar' do
    assert_equal [[10, 2]], Tectonic::Plates.per_side(75, bar_weight: 35)
  end
end

