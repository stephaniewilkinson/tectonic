# frozen_string_literal: true

# Dropping `account_withings.workouts_backfilled_at`, because the read range says what it said.
# #600.
#
# 043 added it as the instant a backfill walk finished, 047 emptied it when that turned out to
# claim years nobody had read (#554), and since then it has been stamped only by a walk that
# reached the earliest stamped set. One thing read it -- the rake task, deciding which year to
# start at -- and only ever for its year.
#
# `workouts_imported_year` and `workouts_imported_through_year` (045, 049) already hold that.
# Where the bottom of the range reaches the lifter's first session, every year from there to
# the top has been read, and the top is the newest of them; `WithingsBackfill.resumed_year`
# starts there. That is the same year the instant gave for a walk, and it is also right for a
# course of presses on the import button, which never stamped the instant and so used to leave
# the task re-reading everything a lifter had already pressed through.
#
# Nothing is lost that anything read. `down` puts the column back empty, which is the state 047
# left it in and the one a missing stamp has always meant: walk from the bottom.
Sequel.migration do
  up do
    alter_table(:account_withings) { drop_column :workouts_backfilled_at }
  end

  down do
    alter_table(:account_withings) { add_column :workouts_backfilled_at, DateTime }
  end
end

