# frozen_string_literal: true

# How far back a lifter has imported their own history, one press at a time. #558.
#
# ## Why a second cursor rather than reusing the one 043 added
#
# `workouts_backfilled_at` is an instant, and what it claims is "everything older than this
# has been read". That is the right shape for `rake withings:backfill`, which walks every
# year from today back to the first stamped set in one go and either finishes or does not.
# It is the wrong shape entirely for a button that reads *one year per press*: a press that
# read 2025 has not read everything older than now, it has read one year, and the only
# honest thing to write down about it is which year that was.
#
# Two columns, then, for two different claims, on the same argument 043 made for keeping
# `workouts_backfilled_at` away from `synced_at`: a cursor shared between two readers with
# different ideas of what it means is how a year goes quietly unread. Nothing here writes
# the rake task's watermark and nothing in the rake task writes this.
#
# ## And why the button does not simply read the other one
#
# Because it can lie. #554: `attempt` stamps `workouts_backfilled_at` whenever the years it
# chose to walk all answered, including a `SINCE`-narrowed walk that never reached the
# earliest session -- so the instant can be stamped for an account with five unread years
# behind it. A button that trusted it would tell a lifter their history was imported when
# most of it never was, which is the one failure this feature exists to prevent.
#
# The two directions of being wrong are not symmetrical, and that is what decides it. A
# cursor that is behind the truth costs one request to a year already stored, and
# `WithingsWorkouts.store` makes re-storing an activity a no-op. A cursor that is ahead of
# the truth loses that year forever, silently, with the page saying everything is imported.
# So this column is only ever moved by a press whose fetch actually answered.
#
# ## An integer year, and nullable
#
# Null means no press has read anything yet, which is different from having read this year
# and is exactly the state every existing row is in. The first press reads the current year;
# each later one reads the year before whatever is written here, and stops when that falls
# below the year of the lifter's earliest stamped set -- the same floor the rake task uses,
# out of Tectonic's own data rather than out of a guess about Withings.
#
# It lives on `account_withings` rather than on `accounts` because it is a fact about a
# connection: disconnecting deletes the row and takes this with it, and a lifter who
# reconnects -- possibly a different Withings account -- starts the walk again from this
# year rather than resuming somebody else's cursor.
Sequel.migration do
  change do
    alter_table(:account_withings) do
      add_column :workouts_imported_year, Integer
    end
  end
end

