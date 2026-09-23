# frozen_string_literal: true

# The other end of the read range, so that "how far back" stops being read as "and everything
# above it". #566.
#
# ## The claim one column was making and could not make
#
# 045 added `workouts_imported_year` and 047 made it the one answer to *how far back has this
# account's history been read* -- written by a press on the settings page and by a walk from a
# terminal alike. What the button then did with it was ask a second question of it: it took
# every year above the cursor to be a year already read, and offered the next year *below*.
#
# That is true for exactly as long as it takes the calendar to move on. A lifter who pressed
# Import through 2023 and worked back to 2019 leaves a cursor of 2019, and in 2026 the page
# reads it as a finished history -- while 2024 and 2025 have never been asked about and never
# will be, because the cursor is below them and `least` only ever moves it further down. The
# same hole swallows the middle of a course of presses that spans a new year: press from 2023
# to 2026 and the years in between are skipped for the same reason.
#
# So the button needs both ends. "Everything from 2019 to 2023" and "everything from 2019 to
# now" are different histories, and one number cannot tell them apart.
#
# ## Why this is a third column and not something derived
#
# Two derivations were looked at and both are the same mistake wearing different clothes.
#
# **The stored activities.** `withings_workouts` holds what came back, so the newest stored
# activity looks like it says how far forward the reading got. It does not: a year with no
# activities in it stores nothing, and this whole module exists because "nothing in this year"
# and "this year was never read" are different claims that the provider cannot tell apart --
# see `WithingsBackfill.walk`, where the same distinction is the difference between a quiet
# year and a rate limit. Deriving the top from rows would retire every quiet year at the top
# of a history, silently, which is #566 again with an extra step.
#
# **`workouts_backfilled_at`.** It carries a date, so the year it was stamped in is the year a
# walk read through to. But it is stamped only by a walk that reached the *bottom* -- 047's
# rule and the whole of #554 -- and a course of presses never stamps it at all, which is
# exactly the state #566 is about. It answers when a read last reached the bottom; it is
# silent about every read that did not.
#
# The three columns are one claim in three parts, and each part is a fact the other two cannot
# state: from `workouts_imported_year` through `workouts_imported_through_year` this account's
# history has been read, and `workouts_backfilled_at` says when a read last reached the bottom
# of it. Drop any one and something goes unread or gets re-read forever.
#
# ## Why the cursors already written are emptied rather than given a top
#
# A row carrying `workouts_imported_year` today is carrying half a claim, and nothing anywhere
# records the other half. The tempting fill is the cursor itself -- claim the one year it
# names and nothing more -- and it is safe, but it is not better than null: a button starting
# from `[2019, 2019]` reads upward to this year and then downward to the floor, which is the
# same number of presses as starting from nothing at all, and it puts a sentence on the page
# ("2020 to 2026 have not been read") that is false about years that were read.
#
# The tempting fill that is actually wrong is this year, and it is wrong in the one direction
# that loses data: it claims every year between the cursor and now, which is the bug.
#
# So null, for the same reason 047 chose null over an invented instant, and with the same
# asymmetry behind it: re-reading a year is a no-op, because `WithingsWorkouts.store` omits
# `workout_id` and `dismissed_at` from its update list and a lifter's answers survive it,
# while a year never read is a year of training nobody is ever offered. The cost of this line
# is at most one extra press for each account that has imported anything; the cost of not
# writing it is a page making a claim about years the database has no record of.
Sequel.migration do
  up do
    alter_table(:account_withings) do
      add_column :workouts_imported_through_year, Integer
    end

    from(:account_withings).update(workouts_imported_year: nil)
  end

  # The column goes; the cursors it emptied do not come back, for the reason 047 gives about
  # its own stamps. Inventing them is precisely the thing #554 and #566 are both about, and a
  # database rolled back here simply reads a year or two it has already read.
  down do
    alter_table(:account_withings) do
      drop_column :workouts_imported_through_year
    end
  end
end

