# frozen_string_literal: true

# An index over completed sets by the day they were completed, so a month of the calendar can
# find the sessions trained in it without asking every session the account has ever had. #599.
#
# ## What the calendar was doing
#
# A session belongs in a month grid if either its planned date or the day it was trained falls
# in it -- `Calendar.within` says why both halves are load-bearing. The second half was written
# as `min(completed_at)` per session, compared to the month. Postgres cannot seek on that, and
# the `OR` only spares the sessions the first half already accepted, so the aggregate ran once
# for every session outside the month: 4,790 times for one grid on a scratch account at 100x
# the reporting one, 88ms of a half-CPU instance.
#
# ## What replaces it
#
# "Some set of this session was completed in the month" as a set lookup: the ids of the
# workouts that own such a set. That is looser than the min -- a session started on the 31st
# and finished on the 1st has a set in both months -- so it is a prefilter, and
# `performed_or_planned_on` still decides which day a session is drawn on, exactly as before.
# A session fetched into the wrong month is keyed to a day outside the grid and drawn nowhere.
#
# ## Why partial, and why this predicate
#
# Only completed sets can answer, and a plan-heavy account's unlifted future sessions are most
# of its sets, so leaving them out is most of what keeps this small. `completed_at IS NOT NULL`
# is enough by itself: `sets_completed_at_needs_a_completion` already refuses a stamp on a set
# that is not completed. **`Workout.completed_between` spells the same predicate and must go on
# spelling it**; the day the two differ, Postgres cannot prove the index covers the query and
# goes back to scanning with every spec still green, which is why
# spec/calendar_spec.rb reads the definition back out of the catalogue.
#
# Concurrently, and so outside a transaction, as 017 and 044 are: this runs as Render's
# pre-deploy command, and a write lock on the sets table would be a failed Done tap.
COMPLETED_ON_INDEX = :sets_completed_on
COMPLETED_ON = Sequel.cast(:completed_at, :date)

Sequel.migration do
  no_transaction

  up do
    add_index :sets, [COMPLETED_ON, :workout_id],
              name: COMPLETED_ON_INDEX, where: Sequel.~(completed_at: nil), concurrently: true
  end

  down do
    drop_index :sets, [COMPLETED_ON, :workout_id], name: COMPLETED_ON_INDEX, concurrently: true
  end
end

