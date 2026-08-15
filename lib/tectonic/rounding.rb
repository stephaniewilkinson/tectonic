# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  # A barbell only changes in increments you can actually load. With 2.5s on each
  # side that is 5 lb, which is why every calculated weight rounds to a multiple
  # of 5 before it is ever written to a set.
  module Rounding
    INCREMENT = 5

    module_function

    def to_increment(weight, increment: INCREMENT)
      (weight / increment.to_f).round * increment
    end
  end
end

