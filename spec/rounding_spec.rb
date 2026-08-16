# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/tectonic/rounding'

describe Tectonic::Rounding do
  it 'leaves multiples of five unchanged' do
    assert_equal 155, Tectonic::Rounding.to_increment(155)
    assert_equal 0, Tectonic::Rounding.to_increment(0)
  end

  it 'rounds to the nearest five pounds' do
    assert_equal 155, Tectonic::Rounding.to_increment(156)
    assert_equal 155, Tectonic::Rounding.to_increment(157)
    assert_equal 160, Tectonic::Rounding.to_increment(158)
  end

  it 'honors a custom increment' do
    assert_equal 20, Tectonic::Rounding.to_increment(23, increment: 10)
    assert_equal 30, Tectonic::Rounding.to_increment(27, increment: 10)
  end
end

