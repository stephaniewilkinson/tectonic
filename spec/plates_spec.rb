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