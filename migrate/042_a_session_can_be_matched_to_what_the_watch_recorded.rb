# frozen_string_literal: true

# Somewhere to put the activity a watch recorded, and somewhere to put the lifter's answer
# about whether it was this session. #520.
#
# ## Why not `health_metrics`
#
# 041 already stores what Withings measured, and the obvious move is to widen it. It is the
# wrong move. A scale reading is an *instant* -- one number, one `measured_at` -- which is
# exactly why #472 could say "sessions join by date rather than by a foreign key" and be
# right. A workout is a *span*: it has two ends, and the whole of what this ticket does is
# compare that span against the span of a Tectonic session. A table whose time column is a
# single instant cannot express an overlap, and a `value`/`unit` pair cannot carry a
# category, a timezone and three heart rates without becoming five rows that have to be
# reassembled by a reader who knows they belong together. So: its own table, because it is
# its own shape.
#
# ## The link is nullable, and so is the refusal, and that is three states
#
# An activity Withings has sent us is one of three things, and all three have to be
# representable or the page cannot tell them apart:
#
#   workout_id NULL, dismissed_at NULL -- nobody has been asked about it yet
#   workout_id SET                     -- the lifter said yes, this is that session
#   dismissed_at SET                   -- the lifter looked at it and said no
#
# The third is not a delete. Withings will hand the same activity back on the next fetch --
# it is still in their account, it is still real -- so a row that was deleted would simply
# return and be proposed again, which is the nagging #520 forbids. Keeping it and stamping
# it is what makes "no" survive the next fetch.
#
# ## A re-fetch must never overwrite an answer
#
# `WithingsWorkouts.store` upserts on `[account_id, external_id]` -- the same idempotency
# pattern WithingsConnection.store uses and the same reason health_metrics has a unique
# index: re-reading an overlapping window is deliberate and must be a no-op rather than a
# duplicate. What is new here is that two of these columns are not Withings' to overwrite.
# `workout_id` and `dismissed_at` are the lifter's decision, and a re-fetch is not new
# information about it -- so the update list on that upsert names neither, and the
# constraint that keeps it honest is written here rather than trusted to the caller.
#
# ## One session, one activity
#
# `workout_id` is unique rather than merely indexed. A session that measured itself twice is
# not a thing that happened, and the failure this prevents is the one that would be hardest
# to see: two rows both claiming a session, the record page picking whichever came back
# first, and the heart rate changing between reloads. Postgres allows as many NULLs as it
# likes under a unique index, so the unmatched rows -- which is most of them -- are
# unaffected.
#
# ## Room for a backfill that is deliberately not being built
#
# #520 declines to match arbitrary past sessions, in those words: "matching an arbitrary
# past session is the hard version of this problem and this flow avoids it entirely". So
# nothing here backfills. But nothing here stops one either: a row carries its own account,
# its own interval and its own idempotency key, and it is stored whether or not a session
# claims it. A backfill would be a reader over this table and a writer of `workout_id`,
# which is to say no migration at all.
#
# ## Where the dismissal for a session with no activity goes
#
# `withings_workouts.dismissed_at` answers "was this activity the session", and there are
# sessions where the honest answer is that there is no activity to ask about -- the lifter
# does not wear the watch on Thursdays. #520 is explicit that the prompt must still be
# dismissible then, permanently, per workout ("a lifter who does not use Withings for a
# given session should see it once and never again for that session"), and there is no
# activity row to carry that. So it goes on the session, where the fact actually lives: it
# is a statement about this workout, not about anything Withings sent.
Sequel.migration do
  change do
    create_table(:withings_workouts) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade
      # Withings' own id for the activity, stable across fetches, which is what makes it
      # usable as the idempotency key. A string rather than an integer because it is
      # somebody else's identifier and we do arithmetic on none of it.
      String :external_id, null: false
      # The two ends, which are the whole point of this table. Withings sends these as unix
      # epoch integers -- `startdate`, `enddate` -- and they are turned into instants on the
      # way in, because an integer column would have to be converted by every reader and one
      # of them would forget.
      DateTime :started_at, null: false
      DateTime :ended_at, null: false
      # The IANA zone the watch was in, stored and not applied. Every stamp in this database
      # is naive and written by this process, so applying a zone here would make these two
      # columns the only ones in the schema that mean something different from their
      # neighbours. It is kept because it is the only record of where the lifter was, and
      # #349's fix will want it.
      String :timezone
      # Withings' integer for what the lifter tapped: 16 is "Lift weights", 17 is "Fitness".
      # Stored as the integer rather than as a name, because the list is theirs and grows,
      # and a name resolved on the way in would freeze today's reading of it.
      #
      # **Evidence, never a filter.** A lifter who tapped "Other" still lifted, and #520 is
      # already clear that an overlap in time is good evidence and not proof. So this raises
      # a candidate's score and is incapable of excluding one.
      Integer :category
      # 0 where a device captured it, 2 where somebody typed it in afterwards. Worth keeping
      # for the same reason `provenance` is shown on a workout: a hand-entered activity is a
      # claim and a captured one is a measurement, and #520's whole case for preferring the
      # watch's numbers rests on them being measured.
      Integer :attrib
      # The fields #518's endpoint will not send unless asked. `getworkouts` returns ids,
      # category and timestamps and nothing else without `data_fields`, so these columns
      # exist precisely because they were requested by name.
      #
      # Calories is a decimal because Withings sends one; rounding on the way in would be
      # inventing precision in the other direction.
      BigDecimal :calories, size: [10, 2]
      # Withings' `effduration`: the seconds it judged were actually spent working, as
      # against the wall-clock span above. Named for what it is rather than for their
      # spelling of it, since nothing else in this schema abbreviates.
      Integer :effective_seconds
      Integer :hr_average
      Integer :hr_min
      Integer :hr_max
      # Withings' `modified`, which moves when they revise an activity. Not used to decide
      # anything yet; stored so that a later fetch can tell a revision from a repeat without
      # having to diff every column.
      DateTime :modified_at
      # Null until a lifter says yes. on_delete: :set_null rather than :cascade, because
      # deleting a session is not a statement that the watch was wrong -- the activity
      # happened, and it goes back to being unclaimed.
      foreign_key :workout_id, :workouts, on_delete: :set_null, unique: true
      DateTime :dismissed_at
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      index %i[account_id external_id], unique: true
      # The fetch reads a window and the matcher reads an interval, and both start from an
      # account. Without this every page view of a workout record scans the table.
      index %i[account_id started_at]
    end

    # "Do not ask me about this session again." Per workout and permanent, which is what #520
    # asks for in so many words, and on the session rather than on an activity row because it
    # has to be sayable about a session that has no activity to point at -- the commonest case
    # for a lifter who owns a watch and does not always wear it.
    alter_table(:workouts) { add_column :withings_dismissed_at, DateTime }
  end
end

