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

    # How a rack turns a calculated weight into a number to put on the bar, and how far
    # apart two rungs of a ramp sit. One object rather than two parameters travelling
    # alongside each other, because they are one fact about one rack -- and #140 is what it
    # looks like when the two drift: the rounding said 124 while the loading said no such
    # weight exists.
    #
    # `round` is a callable so that the modules working a prescription out do not have to
    # know what a plate is. Equipment hands them one that lands on a weight its rack can
    # build; anything with no rack in hand gets the increment rounding below.
    Loading = Struct.new(:increment, :round) do
      # What this app did everywhere before a rack could describe itself: put the weight on
      # a multiple of the increment. A weaker promise than "a weight this rack can build",
      # and the difference is the bug -- but it is still the right answer where there is no
      # inventory to ask, which is every caller that passes nothing.
      def self.by_increment(increment = INCREMENT)
        new(increment, ->(weight) { Rounding.to_increment(weight, increment:) })
      end

      def call(weight) = round.call(weight)
    end
  end
end

