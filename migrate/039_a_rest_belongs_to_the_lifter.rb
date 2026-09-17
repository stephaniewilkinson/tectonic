# frozen_string_literal: true

# How long *this lifter* rests on a movement. #456.
#
# 037 put `default_rest_seconds` on `exercises` and argued the right thing for the wrong
# object. Its reasoning stands and is worth keeping: the bell rings only on a length somebody
# named, because a countdown that rings unasked is the app deciding how long a lifter rests,
# and #263 settled that it does not. What it got wrong is *where* the naming lives.
#
# A library movement has a null account_id and sits on every account's page. `Exercise.owned_by`
# refuses an edit to one for exactly that reason, so a rest on a library row is not merely
# shared -- it is unsayable, and the refusal is correct.
#
# That is not a corner case here. Of the 33 movements the reporting account trains, **nine are
# library rows**, and they are the barbell ones:
#
#     Back Squat, Bench Press, Front Squat, Overhead Press, Decline Bench Press,
#     Good Morning, Barbell Hip Thrust, Deficit Deadlift, Power Snatch
#
# Two of the three main lifts, which are precisely where three minutes matters and precisely
# where the 632s / 9s / 343s gaps in #456's report happened. So 037 shipped a bell that could
# be switched on for accessories and never for squats.
#
# ## The shape 020 already settled
#
# `account_training_maxes` met this exact problem and its comment is the argument verbatim:
#
#   A table rather than a column on `exercises`, and that is the whole design. A library
#   movement has a null account_id and sits on every account's page: a column there would be
#   one account's number displayed to everyone and generated against by everyone, which is
#   exactly the trap `Exercise.owned_by` exists to refuse. Keyed on the pair, the same value is
#   private by construction, and a shared Back Squat can carry a different max for every
#   account that lifts it.
#
# Every word of that is true of a rest. "I take three minutes on squats" is a fact about a
# lifter's training, not about the squat -- the same kind of fact as their training max, their
# bar weight and their session budget, and the third time this app has had to move one onto the
# object it actually belongs to (038 was the last).
#
# ## The column goes rather than staying as a fallback
#
# Keeping both would leave two places a rest can live and a precedence rule between them, and
# the only rows that could use the column are ones the table can hold anyway. One home for one
# fact. The 23 rests already set are carried across to their owning account below, so nothing a
# lifter has said is lost.
#
# The bound is 5..1800 again, matching Bounds::REST, `sets_planned_rest_seconds_off_warmups`
# and the constraint 037 added -- the four describe the same quantity and a bound that differed
# between them is a bound somebody eventually crosses.

# What lifters have already said, moved to where it now lives. Only rows that belong to an
# account: a library row cannot have carried a rest anybody set, because the edit route has
# always refused one -- and any that somehow existed would be a value with no owner to move it
# to. Out here as a lambda rather than inline so the migration block stays readable at a glance.
CARRY_RESTS_ACROSS = lambda do |db|
  db.from(:exercises).exclude(account_id: nil).exclude(default_rest_seconds: nil)
    .select(:account_id, Sequel[:id].as(:exercise_id), Sequel[:default_rest_seconds].as(:seconds))
    .each { |row| db.from(:account_exercise_rests).insert(row) }
end

# And back onto the movement, column and all. Lossy by nature: a column can hold one answer, so
# a movement two accounts have both named keeps whichever was written last. That is the point of
# the table rather than a fault in this reversal.
PUT_RESTS_BACK = lambda do |db|
  db.alter_table(:exercises) do
    add_column :default_rest_seconds, Integer
    add_constraint(:exercises_default_rest_seconds_in_range) do
      Sequel.lit('default_rest_seconds IS NULL OR (default_rest_seconds >= 5 AND default_rest_seconds <= 1800)')
    end
  end
  db.from(:account_exercise_rests).order(:id).each do |row|
    db.from(:exercises).where(id: row[:exercise_id], account_id: row[:account_id])
      .update(default_rest_seconds: row[:seconds])
  end
end

Sequel.migration do
  up do
    create_table(:account_exercise_rests) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      foreign_key :exercise_id, :exercises, null: false, on_delete: :cascade
      # Not null: a row here *is* the naming. Clearing a rest deletes the row rather than
      # writing a null into it, so "no bell" has one spelling and not two.
      Integer :seconds, null: false
      # When it was said, on 020's terms: recorded rather than acted on. Nothing expires a
      # rest, and a reader cannot even ask how old one is of a number with no date on it.
      Time :set_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      # One rest per lifter per movement. The pair is the natural key and the unique index is
      # what makes insert_conflict an upsert rather than a second row. It indexes account_id
      # too, since that leads the pair, which is why there is no separate index for it.
      unique %i[account_id exercise_id]
      # exercise_id needs its own, on 020's argument and #233's rule: a foreign key with no
      # index leading with its column makes both the lookup and the parent's cascading delete
      # scan the whole table. spec/foreign_key_index_spec.rb holds every key in the schema to
      # this and caught its absence here.
      index :exercise_id
      constraint(:account_exercise_rests_in_range) { Sequel.lit('seconds >= 5 AND seconds <= 1800') }
    end

    CARRY_RESTS_ACROSS.call(self)

    alter_table(:exercises) do
      drop_constraint(:exercises_default_rest_seconds_in_range)
      drop_column :default_rest_seconds
    end
  end

  down do
    PUT_RESTS_BACK.call(self)
    drop_table(:account_exercise_rests)
  end
end

