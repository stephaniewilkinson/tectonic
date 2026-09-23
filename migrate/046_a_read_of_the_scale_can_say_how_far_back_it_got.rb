# frozen_string_literal: true

# Somewhere for a read of the scale to record progress it has made without claiming to be
# finished. #557.
#
# ## The two questions one column was answering
#
# `account_withings.synced_at` means *everything up to here has been read*, and 041 wrote it
# for the poller: it is the resume point a forward window starts a week behind, and the
# instant the settings page and the reading tools report as how fresh the numbers are. It
# moves only for a window that arrived whole, which is right, and it is the only thing a
# measurement fetch could write.
#
# A first read has no `synced_at`, so it reaches back a year -- the widest and most expensive
# request this app makes, and therefore the one likeliest to be refused partway. When that
# happened the rows that arrived were stored and nothing moved, so the next read asked for
# the same year, and the one after that. Nothing was lost, because the rows are idempotent;
# what never happened was the window getting any narrower. An account that could not finish
# its first year in one go never reached the cheap steady state the fifteen-minute floor is
# built around.
#
# Stamping `synced_at` anyway was the one fix ruled out: a truncated read has not read
# everything up to anywhere, and saying it has trades a slow loop for readings that are
# silently missing -- which is the failure the `:incomplete` outcome exists to prevent.
#
# ## Which is why it is a second column and not a reuse of the first
#
# This one answers the other question: *how far back has this account been read*. The two
# together describe one interval -- from `measures_read_back_to` forward to `synced_at`,
# every reading has been fetched -- and a long walk backwards can record where it got to
# without touching what the poller depends on. 043 drew the same line for the same reason,
# keeping `workouts_backfilled_at` off `synced_at` so a workout fetch could not tell the
# measurement poll it had read a window of bodyweights nobody had fetched.
#
# ## What an existing connection already has, and why it is written down rather than assumed
#
# A row already carrying a `synced_at` has had a year read: the old code moved that column for
# a window that arrived whole and for nothing else, and the window on a first read was a year
# wide. So the update below is not a guess dressed as a measurement -- it is that fact, stated
# in the weakest form that is certainly true. A year back from the *latest* success is a
# shorter reach than a year back from the first one, and the first one is the read that
# actually went that deep, so every instant this claims was read really was.
#
# It matters that it is written rather than inferred from the column being null. Null has to
# go on meaning "nothing has been read back to anywhere" for a connection that has never
# finished a piece, and after this migration a fetch writes this column on every piece that
# arrives -- so a row that has a `synced_at` and no reach would otherwise be two different
# situations wearing one value, and the reading of it that is wrong re-walks a year on every
# account that already has one.
#
# The year is spelled out here rather than read from `WithingsMeasures::BACKFILL`, because a
# migration that loads the app is a migration whose meaning changes when the app does, and
# this one has to keep saying what it said on the day it ran.
#
# Nullable, because an account whose first read was refused before any piece of it arrived has
# got nowhere and has nothing true to put here.
Sequel.migration do
  up do
    alter_table(:account_withings) do
      add_column :measures_read_back_to, DateTime
    end

    from(:account_withings).exclude(synced_at: nil)
                           .update(measures_read_back_to: Sequel.lit("synced_at - interval '365 days'"))
  end

  down do
    alter_table(:account_withings) do
      drop_column :measures_read_back_to
    end
  end
end

