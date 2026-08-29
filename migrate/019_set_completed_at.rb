# frozen_string_literal: true

# When each set was actually done. #281.
#
# The issue arrived as a screenshot of another app's countdown sheet -- suggested times,
# picker wheels, Cancel and Start. What is wanted underneath it is the opposite of a gadget:
# to track overall time for the workout, the sets, and the gaps between sets. That is
# measurement, and this app had nothing to measure with.
#
# It looks as though it did, which is the trap. `sets.created_at` exists and defaults to
# CURRENT_TIMESTAMP, but it is the moment the *row* was written, and ProgramGenerator writes
# a whole week of them at once -- a Thursday session generated on Sunday carries Sunday on
# every set, inside the same second. Read as a training time it would say the week happened
# all at once. `workouts.finished_at` (014, #218) says when the lifter stopped, and nothing
# said when they started or when anything in between happened.
#
# One column, and it carries the whole feature. Overall is the first stamp against the last
# or against finished_at; a gap is a subtraction between two of them. There is no second
# column, and that is worth being blunt about, because the obvious next one is the one this
# cannot have.
#
# **One tap per set cannot measure how long a set took.** The interval between two Done taps
# is the rest plus the working time of the set that ended it, and separating them needs a
# second event -- a Start tap -- on every set. That is refused. This screen's premise is one
# tap, one-handed: _lift_panel.erb's own notes say the revision boxes are the working set's
# size because playing a warmup down "applies to what is read, not to what is typed one
# handed with chalk on", and that the rating is answered "45 times in a session, one-handed,
# with chalk on". Doubling the taps to buy a number would be paid for at the worst moment,
# and a forgotten Start is indistinguishable from an instant set -- so the second tap would
# make both halves unreliable rather than one half exact.
#
# So what is measured between two sets is called a **turnaround** everywhere, and never a
# rest. It is rest plus the next set's working time, and naming it "rest" would be reporting
# a number the app cannot see. Timed sets are the exception and need no help: their length is
# already stated in duration_seconds, which is what `measure` exists to say.
#
# A rep set gets no duration_seconds and could not have one: sets_measures_one_way from 009
# refuses a duration on a row counted in reps, and that constraint is right -- a set counts
# one way or the other.
#
# **The constraint is the sharp edge here.** completed_at without is_completed is a set that
# was never done carrying the instant it was done, which is not a state any reader could make
# sense of, and it is the state every un-complete path would leave behind if it cleared one
# and not the other. Refusing it means those paths have to clear both, which is exactly the
# point: the rule is enforced where it cannot be forgotten rather than remembered at five
# call sites. WorkoutSet.completion is the helper they all go through.
#
# `is_completed IS TRUE` rather than `= true`, and the difference is not stylistic. 001
# declares the column `TrueClass :is_completed, default: false` with no `null: false`, so it
# is nullable -- and `NULL = true` is NULL, which a CHECK treats as satisfied. A row with a
# null completion and a stamp on it would slip through the `= true` spelling.
#
# Nullable with no backfill and no default. Every set that exists was completed, or not,
# before anything was measuring, and inventing a time for it would be inventing training
# history. Timing reports nothing rather than something wrong for those, which is the
# distinction the readers below are all built on.
Sequel.migration do
  up do
    alter_table(:sets) do
      add_column :completed_at, DateTime
      add_constraint(:sets_completed_at_needs_a_completion) do
        Sequel.lit('completed_at IS NULL OR is_completed IS TRUE')
      end
    end
  end

  down do
    alter_table(:sets) do
      drop_constraint(:sets_completed_at_needs_a_completion)
      drop_column :completed_at
    end
  end
end

