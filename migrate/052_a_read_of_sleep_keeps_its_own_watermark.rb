# frozen_string_literal: true

# Somewhere for a read of the night to record when it happened, that no other read may use.
# #579.
#
# ## The column this is not, and why that is the whole of it
#
# `account_withings.synced_at` is the measurement fetch's resume point. 041 wrote it, #518
# reads it to decide where the next window of weigh-ins starts, and 046 and 047 spent two
# migrations narrowing what it is allowed to claim: *everything up to here has been read*,
# moved only by a window that arrived whole. A sleep read that stamped it would tell the
# measurement poller it had already read a week of weigh-ins that nobody has ever fetched,
# and the weigh-ins would go missing with nothing anywhere to show it.
#
# That is not a hypothetical. It is the same bug twice already: #554, where a workout
# backfill's stamp was kept off `synced_at` for exactly this reason and
# `WithingsWorkouts.fetched?` carries the comment saying so, and #557, where a truncated
# measurement read stamping the column anyway was the one fix ruled out. 043 drew the line
# first, 046 drew it again, and this is the third fetch to arrive at it. Two different fetches
# wanting one watermark between them is how data goes quietly missing, and the cost of a
# column is one `add_column`.
#
# ## Why it is `_read_at` and not `_synced_at`
#
# The three watermarks already here each make a claim about a *stretch of time*:
# `measures_read_back_to` forward to `synced_at` has been read; `workouts_imported_year`
# through `workouts_imported_through_year` has been walked. Naming this one to match would
# invite the same reading, and it would be a lie.
#
# This column says only **when the last sleep read finished**. It is not a resume cursor,
# because the sleep read does not resume from anywhere: Withings' reference caps
# `Sleep v2 - Getsummary` at *"7 days maximum"* per call, so the window is the seven days
# ending now, every time, chosen by the calendar rather than derived from this value. Nothing
# reads it to decide what to ask for. It is the staleness floor -- the fifteen minutes that
# keeps a conversation of a dozen tool calls to one HTTP call, which is what Withings' *"do
# not poll more than once every 10 minutes per user"* asks of us -- and it is what a reader is
# told when it wants to say how fresh the numbers are.
#
# The distinction earns its keep the moment somebody is away for a fortnight. A read today
# covers the last seven nights and the week before them was never asked about. A column
# called `sleep_synced_at` would be claiming that week; this one is not, and the gap is
# legible from its face -- a value more than seven days old is a value with unread nights
# behind it. Closing that gap is a backfill, with its own reach column, and is deliberately
# not pre-empted here: 046 and 049 are both migrations written because a single number was
# made to answer two questions, and inventing the second one before there is a walk to write
# it is how the third gets written.
#
# ## Nullable, and null means never
#
# A connection whose sleep has never been read has nothing true to put here, and null is what
# that is. `WithingsSleep.fresh?` reads it as "no read has happened", which is the only
# reading it can bear -- and unlike 046, there is nothing to backfill onto the rows that
# already exist, because no sleep read has ever run anywhere.
Sequel.migration do
  change do
    alter_table(:account_withings) do
      # When a sleep read last finished. Not a resume point, and never `synced_at` -- see
      # the file comment above, and `WithingsWorkouts.fetched?`, which refuses the same thing
      # for the same reason.
      add_column :sleep_read_at, DateTime
    end
  end
end

