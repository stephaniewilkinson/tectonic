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

    # How long a session of this block should take: what the block says, else what the lifter
    # said once on their settings page. #446.
    #
    # The column on `programs` has existed since 032 and no block has ever carried one, so the
    # whole budget feature -- the warning at generation, the comparison in SessionLength --
    # was built and never ran. #458 is why that is a wrong-object problem rather than a missing
    # screen: it asks for no CRUD interface and names the exception, "one number per movement
    # and one editable field".
    #
    # Everything else on this row is a decision belonging to its block and changing between
    # blocks -- preferred_reps, is_ascending, start_date. A time budget is not. "I have an hour
    # to train" is a fact about a lifter's week, the same next block and the one after, and
    # asking it again on every block written is how it comes to be asked never.
    #
    # The block still wins where it says something, because a peaking block really can be
    # longer than an ordinary week and that *is* a fact about that block. What changes is that
    # a block saying nothing inherits an answer rather than disabling the check.
    #
    # Read here rather than at the call sites, so the two readers -- the warning and the
    # session estimate -- cannot come to different conclusions about whose hour it is.
    def budget_minutes
      time_budget_minutes || DB[:accounts].where(id: account_id).get(:time_budget_minutes)
    end

    #
    # Off the weeks already loaded where a caller eager loaded them, which `ensure_ahead` does
    # so that asking after two weeks of every running block is not a query per question (#595).
    # Only then: a block whose weeks were never loaded asks the table, so a caller that has just
    # added a week is not answered from a list read before it existed.
    def week(number)
      return program_weeks.find { |week| week.number == number } if associations.key?(:program_weeks)

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

