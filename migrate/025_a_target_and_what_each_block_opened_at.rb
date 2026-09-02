# frozen_string_literal: true

# What a lifter is aiming at, and what they have actually been training against. #308.
#
# `list_programs` shows blocks and nothing relates them, so "am I on pace" -- the question a
# competitive lifter actually has -- could not be asked. Two tables, answering the two halves
# of it, plus a read over both that is pure query and needs no schema.
#
# ## account_goals: what "on pace" is pace *for*
#
# Without a target the app can show a trend and cannot say whether it is enough.
#
# **On the account rather than on the block**, and the reason is that a block already states
# its own aim: the generator writes `planned_weight` on every set, so the heaviest planned
# load per movement *is* what this cycle is aiming at, already stored and already readable.
# What was missing is the standing one -- "squat 405 by March 14" -- which outlives any block
# and belongs beside `account_plates` and `account_training_maxes`, the way `bar_weight` and
# `week_starts_on` sit beside the account rather than on the thing they describe.
#
# **A date per goal rather than one meet date on the account.** A meet has a date, but so
# does "405 before the summer", and a lifter aiming at a total is aiming at three numbers on
# one day and possibly a fourth on another. One date per goal expresses all of that; one date
# for the account expresses one of them and quietly mis-files the rest.
#
# `by_date` is nullable, because a target with no deadline is still a target and refusing it
# would be the app insisting on a plan the lifter has not made. Nothing here computes
# "behind schedule": the read shows the goal, the date and what each block opened at, and the
# assistant judges -- the same division #263 settled.
#
# ## account_training_max_statements: what a past block really opened at
#
# `TrainingMax.for` answers "what is this max" by taking the stated row where there is one
# and deriving from completed sets otherwise. The derived branch is already as-of a date, so
# "what did block 2 open at" is exact for it. The stated branch is not, and cannot be:
# `account_training_maxes` is unique on the pair and `replace` upserts, so a stated max has
# one row and one `stated_at`, and restating 315 as 325 leaves nothing behind saying it was
# ever 315. A block opened at 315 would report 325 forever after.
#
# **An append-only log beside the current answer, rather than history in the table itself.**
# Dropping the unique index and resolving the stated branch by latest-on-or-before would give
# the same reporting and take something real away: #291 fixed a block's denominator at its
# start date, and left restating a max as the escape hatch -- regenerate and the block moves.
# Under as-of resolution regenerating an old block would price it off the max current at its
# start date, so the escape hatch closes.
#
# So resolution does not change at all. `TrainingMax.for` stays exactly as it is, and this
# table is read by reporting and by nothing that writes a load. The boundary is worth stating
# once and holding to: **one rule decides what to lift, and it is not this one.** Two rules
# for the same question is the thing TrainingMax exists to prevent; two rules for two
# different questions -- "what is the max" and "what did you say, and when" -- is only
# honest, because the second is a question the app genuinely could not answer.
#
# Backfilled from the current rows, one statement each at its own `stated_at`, which is the
# one statement we know actually happened. A block that started *before* a lifter's earliest
# statement finds nothing here and falls through to the derived reading as of that date --
# which is exactly right, because that is what the app was generating against back then.
GOALS_TABLE = lambda do |db|
  db.create_table(:account_goals) do
    primary_key :id
    foreign_key :account_id, :accounts, null: false
    # ON DELETE CASCADE for 020's reason: this is a preference *about* a movement rather
    # than training, so a movement that is gone leaves a goal about nothing, and
    # `rake exercises:merge` really does delete movements.
    foreign_key :exercise_id, :exercises, null: false, on_delete: :cascade
    # numeric(7, 2) to match sets.weight and account_training_maxes.pounds. A goal is
    # compared against a max, so it has to be the same kind of number as one.
    BigDecimal :pounds, size: [7, 2], null: false
    # When it is wanted by, or null for a target with no deadline.
    Date :by_date
    Time :set_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    # A goal of zero or less is not a goal, and one saved by accident would make every
    # comparison against it meaningless. Written as a literal for 020's reason: the block
    # form compiles a Sequel virtual row, which has no `positive?`.
    constraint(:account_goals_positive) { Sequel.lit('pounds > 0') }

    # One goal per account per movement, so restating it answers the same question again
    # rather than asking a second one. Leads on account_id, which is why that key needs no
    # index of its own.
    unique %i[account_id exercise_id]
    index :exercise_id
  end
end

STATEMENTS_TABLE = lambda do |db|
  db.create_table(:account_training_max_statements) do
    primary_key :id
    foreign_key :account_id, :accounts, null: false
    foreign_key :exercise_id, :exercises, null: false, on_delete: :cascade
    # Nullable, unlike the column it mirrors, because "I no longer state one" is a thing a
    # lifter says and the log has to be able to hold it. Emptying the box on the form
    # clears the stated max and hands the movement back to the derived estimate; without a
    # row for that, a block run afterwards would find the statement *before* the clear and
    # report a number it was never generated against. A null here means the estimate was
    # in charge from this moment, which is what was actually true.
    BigDecimal :pounds, size: [7, 2]
    # Both halves of #292, because a statement has to be reconstructable in full: "500 at
    # 90%" and "450 at 100%" generate identically and are not the same thing to say.
    Integer :train_at_percent, null: false, default: 100
    Time :stated_at, null: false, default: Sequel::CURRENT_TIMESTAMP

    # Absent is allowed and zero is not, which is 008's distinction in a third place: a
    # null says nothing was stated, and a zero would be a stated max of nothing.
    constraint(:account_training_max_statements_positive) do
      Sequel.lit('pounds IS NULL OR pounds > 0')
    end

    # No unique constraint anywhere: repetition is the point of this table. The index is
    # the shape every read of it has -- one account, one movement, latest first -- and it
    # leads on account_id, which covers that key.
    index %i[account_id exercise_id stated_at]
    index :exercise_id
  end
end

# Every stated max as it stands becomes its own first statement. `stated_at` is copied rather
# than defaulted, so a max set fourteen months ago does not arrive in the log dated today and
# make every block since look as though it opened at today's number.
BACKFILL_STATEMENTS = lambda do |db|
  db.from(:account_training_max_statements)
    .insert(%i[account_id exercise_id pounds train_at_percent stated_at],
            db.from(:account_training_maxes)
              .select(:account_id, :exercise_id, :pounds,
                      Sequel.function(:coalesce, :train_at_percent, 100), :stated_at))
end

# `up`/`down` rather than `change`, because the backfill is an insert and Sequel cannot
# reverse one. Written out rather than silenced: a `change` block holding a statement it
# cannot undo is a migration that claims to be reversible and is not, which is worse than
# saying plainly that going back drops the two tables and everything in them.
Sequel.migration do
  up do
    GOALS_TABLE[self]
    STATEMENTS_TABLE[self]
    BACKFILL_STATEMENTS[self]
  end

  # The goals and the log go. Nothing else is touched -- `account_training_maxes` is the
  # source the log was built from and still holds every current answer, so a downgrade loses
  # the targets and the history of restatements and no training at all.
  down do
    drop_table(:account_training_max_statements)
    drop_table(:account_goals)
  end
end

