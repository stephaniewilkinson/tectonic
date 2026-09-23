# frozen_string_literal: true

# Somewhere for a backfill to leave a proposal, and somewhere for it to record how far back
# it has read. The historical half of #520, which #520 declined.
#
# ## This reverses a decision, deliberately
#
# #520 refuses to match arbitrary past sessions in so many words -- "matching an arbitrary
# past session is the hard version of this problem and this flow avoids it entirely" -- and
# 042 wrote that refusal into its own notes. The owner was asked and chose to do it anyway,
# as a second piece after the forward flow rather than instead of it. So this is a reversal
# rather than an oversight, and it is the *scope* that is reversed and nothing else: every
# pairing a backfill finds is still a proposal the lifter confirms or dismisses, and the
# columns that carry their answer are still untouchable by a fetch.
#
# ## Why a proposal needs a column at all
#
# The forward flow never stores one. It asks Withings on every view of a session under a day
# old, scores what comes back, and renders the winner -- which is affordable precisely
# because the window is a day wide and the answer is wanted seconds after the lifter tapped
# finish.
#
# A backfill cannot work that way and must not. Proposing against a decade means asking
# Withings once per year of history, and if that judgement were recomputed per page view
# then every visit to an old workout record would be a live API call -- which is how a
# read-only integration gets itself rate-limited, and a throttle is the one failure the
# record page cannot render honestly (see `Withings.answered`, and status 601). So the walk
# happens once, in a rake task, and what it concluded is *written down*: `proposed_workout_id`
# is the backfill saying "this activity looks like that session, ask about it", and the
# record page reads it without asking anybody anything.
#
# ## Three columns for three different things, not one column reused
#
# `workout_id` is the lifter's yes. `dismissed_at` is the lifter's no. `proposed_workout_id`
# is the app's guess, and it is emphatically not either of the other two: folding a guess
# into `workout_id` would be the silent matching #520 refuses most loudly, and a lifter
# would find a year of sessions wearing heart rates nobody agreed to.
#
# Unique for the same reason `workout_id` is unique: a session offered two activities at
# once is a page that shows whichever came back first and changes its mind between reloads.
# Postgres allows as many NULLs as it likes under a unique index, and almost every row here
# is NULL in this column, so the constraint costs the unmatched rows nothing.
#
# on_delete: :set_null, again matching `workout_id`: deleting a session is not a statement
# that the watch was wrong. The activity happened, and it goes back to being unoffered.
#
# ## The watermark is the backfill's own, and that is the whole point of it
#
# `account_withings.synced_at` is the measurement poller's resume cursor -- where #518 picks
# up reading bodyweights. A workout fetch that stamped it would tell that poller it had
# already read a window of measurements it has never seen, and the readings in that window
# would simply never arrive. Nothing would raise; a chart would just be missing a fortnight.
# Two fetches wanting one watermark between them is how data goes quietly missing, so this
# fetch gets its own.
#
# Stamped only when a walk completed -- every year asked for and every year answered. A
# partial walk leaves it exactly as it was, because its meaning is "everything older than
# this instant has been read", and a walk that was throttled in 2021 cannot say that.
Sequel.migration do
  change do
    alter_table(:withings_workouts) do
      add_foreign_key :proposed_workout_id, :workouts, on_delete: :set_null, unique: true
    end

    alter_table(:account_withings) do
      add_column :workouts_backfilled_at, DateTime
    end
  end
end

