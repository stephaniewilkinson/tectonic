# frozen_string_literal: true

# Forgetting every backfill watermark, because none of them can be trusted to mean what the
# code now reads them as. #554.
#
# ## What the old rule was, and why the column has to be emptied rather than reinterpreted
#
# 043 introduced `account_withings.workouts_backfilled_at` and said of it: "Stamped only when
# a walk completed -- every year asked for and every year answered." That was true of the
# code and false of the claim, because "every year asked for" is the walk's own choice of
# years and `rake withings:backfill ACCOUNT_ID=1 SINCE=2024` asks for two of them. The
# instant's meaning is "everything older than this has been read", `years_to_walk` floors a
# later run at the year it holds, and so a lifter whose earliest stamped set is 2019 could be
# left with 2019 through 2023 unread and unreadable -- by a run that reported a completed
# walk, because from its own point of view it had completed one.
#
# `WithingsBackfill.settle` now stamps only where the oldest year the walk actually read sits
# at or below the year of that lifter's earliest stamped set, so from here on the sentence in
# 043 is true of the code as well. What it cannot do is reach backwards. A stamp already in
# this column was written under the old rule, and nothing stored anywhere says which years the
# run that wrote it asked for -- a stamp from a full walk and a stamp from `SINCE=2024` are
# the same timestamp. So every one of them goes.
#
# ## The cost of clearing one that was honest, against the cost of keeping one that was not
#
# Clearing a stamp that a full walk had earned costs that account one more full walk: a
# request per year of its history, once, on the next run of a task an operator runs by hand.
# Keeping a stamp that a narrowed walk wrote costs that account every year behind the stamp,
# permanently and silently, with the task printing a completed walk each time. This is the
# same asymmetry `WithingsBackfill.next_year` turns on and it is not close: re-reading a year
# is a no-op, because `WithingsWorkouts.store` omits `workout_id` and `dismissed_at` from its
# update list and a lifter's answers survive it, while a year never read is a year of training
# nobody is ever offered.
#
# ## What is deliberately not written here
#
# `workouts_imported_year`, which is the other half of the same claim -- how far back the
# history has been read, as against when a read last reached the bottom of it. It would be
# tempting to seed it from the cleared stamps, and there is nothing honest to seed it with:
# the stamp says when, never how far. Null is the truthful answer to a question this database
# has no record of, and it puts every account on the cheap side of the asymmetry above.
Sequel.migration do
  up do
    from(:account_withings).update(workouts_backfilled_at: nil)
  end

  # Irreversible on purpose rather than by omission. Rolling this back would mean inventing
  # instants for the accounts it emptied, and an invented watermark is precisely the thing
  # #554 is about; a database that has run this simply reads a year or two it has already read.
  down do
    # Nothing to put back.
  end
end

