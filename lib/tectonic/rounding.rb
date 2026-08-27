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
    # Data rather than Struct: this is read and never written, and Struct would hand every
    # field a setter, so `loading.increment = 5` would compile and change the rack under a
    # half-generated week. Data has none, which is the whole reason it is Data.
    #
    # Both construction sites pass keywords. Data would take them positionally too, so that
    # is a convention rather than something the class enforces -- but the two fields are an
    # Integer and a Proc, and swapping them raises somewhere far from the swap, so naming
    # them at the call site is worth the few characters.
    #
    # `round` is a callable so that the modules working a prescription out do not have to
    # know what a plate is. Equipment hands them one that lands on a weight its rack can
    # build; anything with no rack in hand gets the increment rounding below.
    Loading = Data.define(:increment, :round) do
      # What this app did everywhere before a rack could describe itself: put the weight on
      # a multiple of the increment. A weaker promise than "a weight this rack can build",
      # and the difference is the bug -- but it is still the right answer where there is no
      # inventory to ask, which is every caller that passes nothing.
      def self.by_increment(increment = INCREMENT)
        new(increment:, round: ->(weight) { Rounding.to_increment(weight, increment:) })
      end

      def call(weight) = round.call(weight)
    end
  end
end

