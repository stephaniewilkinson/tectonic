# frozen_string_literal: true

require_relative 'spec_helper'

# The sets column on a movement's history, one row per session since DESIGN.md.
describe 'a session said the way a lifter says it' do
  def summary(*sets)
    Tectonic.allocate.send(:sets_summary, sets.map { |weight, reps| { weight:, reps: } })
  end

  it 'collapses sets alike into a count' do
    assert_equal '3 × 5 at 135', summary([135, 5], [135, 5], [135, 5])
  end

  it 'keeps a ramp in the order it was lifted' do
    assert_equal '95 × 5, 2 × 5 at 135, 185 × 3', summary([95, 5], [135, 5], [135, 5], [185, 3])
  end

  it 'says a set with no load as its reps' do
    assert_equal '3 × 12', summary([nil, 12], [nil, 12], [nil, 12])
    assert_equal '12 reps', summary([nil, 12])
  end
end

