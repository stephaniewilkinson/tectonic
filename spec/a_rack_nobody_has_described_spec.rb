# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/equipment'

# #632. Every account that never opened settings lifted on a rack of two pairs of 45s, which
# loads nothing past 395 -- so a block asking a new lifter for a 455 squat was written as 395
# with nothing said. The default is a gym's rack now.
describe 'the rack an account has before it describes one' do
  let(:rack) { Tectonic::Equipment.default }

  it 'loads what a strong lifter asks for, rather than capping it at 395' do
    [405, 455, 500, 605].each { |weight| assert_equal weight, rack.loadable(weight, is_barbell: true) }
  end

  # The ceiling moved; the increment did not. The small plates decide the smallest jump.
  it 'rounds to the same increments it always did' do
    assert_equal 5, rack.increment
    assert_equal 135, rack.loadable(136, is_barbell: true)
  end
end

