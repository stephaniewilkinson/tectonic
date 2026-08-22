# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  # How a quantity is counted: in reps, or in seconds. Two named things rather than a
  # free string, so they are handed back as symbols and compared as symbols.
  #
  # The column itself stays text, because Postgres has no symbol type, and Sequel
  # typecasts a symbol back to text on the way in -- so writing `measure: :time` through a
  # model stores 'time' without anything further.
  #
  # Reading it in a *dataset* is the one place this cannot be done, and it is worth being
  # explicit about why: Sequel reads a symbol in a filter value as the name of a column,
  # so `where(measure: :time)` compiles to `"measure" = "time"`, comparing two columns
  # rather than matching a value. Every dataset filter therefore uses STORED, and the
  # symbols stop at the model boundary.
  module Measured
    REPS = :reps
    TIME = :time
    NAMES = [REPS, TIME].freeze
    # The same two, as the column holds them, for datasets and migrations.
    STORED = NAMES.map(&:to_s).freeze

    module_function

    # A measure from anywhere -- a JSON argument, a column, a caller -- as the symbol, or
    # nil when it is not one of the two. Nil rather than a raise, so the writer can refuse
    # it by name with the rest of the prescription's problems.
    def cast(value)
      symbol = value.respond_to?(:to_sym) ? value.to_sym : nil
      symbol if NAMES.include?(symbol)
    end

    def stored(value)
      cast(value)&.to_s
    end
  end
end

