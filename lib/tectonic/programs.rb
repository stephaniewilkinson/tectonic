# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'program_weeks'

class Tectonic < Roda
  # A training block: a start date and the weeks written inside it. Weeks are rows
  # rather than a scalar column, so a block can say which of its weeks is a deload
  # before anyone inspects its loads, and so week 2 is recognisably the same block as
  # week 1 rather than another top-level row that happens to share a name.
  class Program < Sequel::Model
    one_to_many :program_weeks, order: :number

    # How long the block is, taken from the weeks it actually holds rather than kept in
    # a column beside them, because the two would eventually disagree and there is no
    # reading of a plan where the count is right and the weeks themselves are wrong.
    def weeks
      program_weeks_dataset.count
    end

    def week(number)
      program_weeks_dataset.where(number:).first
    end

    # The week whose seven days contain this date, or nil when the date falls outside
    # the block. Callers use it to mean "the week we are in", so being told that nothing
    # covers today is the useful answer for a block that has not started or has already
    # finished -- better than silently generating whichever week is nearest.
    def week_on(date = Date.today)
      return nil if date < start_date

      week(((date - start_date).to_i / 7) + 1)
    end
  end
end

