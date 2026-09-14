# frozen_string_literal: true

# A block can say how long its sessions are allowed to take. #408.
#
# A generated deadlift day came out at 29 sets across four loaded movements -- roughly ninety
# minutes against a one-hour cap -- and nothing flagged it, because there was no cap anywhere
# for anything to flag it against. The lifter found out by running out of time.
#
# The estimate half of this needs no column: since #281 every working set carries
# planned_rest_seconds, so a day's length is arithmetic on rows that already exist. What was
# missing is the number to compare it to, and that is a fact about the block -- "this is a
# lunchtime programme" is a constraint the whole block was written under, not a property of
# any one day in it.
#
# **On the programme rather than on the account**, which is the one real choice here. A
# lifter is not one kind of lifter forever: a twelve-week meet prep block and the maintenance
# block after it have different amounts of time available, and hanging the number off the
# account would make changing it rewrite the constraint the earlier block was judged against.
# A block is also the thing that gets written, which is where the comparison belongs.
#
# **Nullable, and null means "do not compare".** Most blocks are not written against a clock
# and should not acquire an opinion about one. A default would put every existing block --
# every block anybody has ever written here -- inside or outside a budget nobody set, and the
# first thing that happened would be a warning about a session that is perfectly fine.
#
# **Minutes rather than seconds**, unlike every other duration in this schema. The others are
# measured or prescribed to the second because that is the precision they are used at; this
# one is typed in by a person saying "about an hour", and a column that can hold 3607 seconds
# invites a precision the number does not have.
#
# The range is 10 to 300. The lower bound refuses a budget no session could meet -- a ten
# minute session is two warmup sets -- and the upper is five hours, past any real session and
# well past the point where a budget is doing anything. A bad value here is not one bad row:
# it is a warning on every day of every week the block generates.
Sequel.migration do
  up do
    alter_table(:programs) do
      add_column :time_budget_minutes, Integer
      add_constraint(:programs_time_budget_in_range) do
        Sequel.lit('time_budget_minutes IS NULL OR time_budget_minutes BETWEEN 10 AND 300')
      end
    end
  end

  down do
    alter_table(:programs) do
      drop_constraint(:programs_time_budget_in_range)
      drop_column :time_budget_minutes
    end
  end
end

