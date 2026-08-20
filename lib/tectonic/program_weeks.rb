# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # One week of a block, and the arithmetic that turns its position in the block into
  # calendar dates. Nothing here is stored: a week knows its number, and the block
  # knows when it starts, so every date follows from those two and cannot drift out of
  # step with them the way a stored date would once a block was moved.
  class ProgramWeek < Sequel::Model
    many_to_one :program
    one_to_many :program_days

    # Weeks are seven days counted from the block's start date rather than calendar
    # weeks snapped to a Monday. A block that opens on a Wednesday therefore has a
    # first week running to the following Tuesday, so its opening days are inside week
    # one instead of being lost to the part of the calendar week already spent.
    def start_date
      program.start_date + ((number - 1) * 7)
    end

    # A program day names a weekday, not a date, so it lands on the first matching
    # weekday inside this week's seven days. Every weekday occurs exactly once in any
    # seven-day window, which is what makes this total: one date per program day, for
    # any week of any block, however the block happens to start.
    def date_for(weekday)
      start_date + ((weekday - start_date.wday) % 7)
    end

    # The dates this week spans, for asking whether something falls inside it.
    def dates
      start_date...(start_date + 7)
    end
  end
end

