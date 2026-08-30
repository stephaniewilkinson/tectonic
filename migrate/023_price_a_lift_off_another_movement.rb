# frozen_string_literal: true

# A percentage can be of another movement's max. #295.
#
# `percent_of_max` resolved against the lift's own exercise, so a percentage was always a
# percentage of that exact movement's history. Two ordinary ways of writing a block were
# therefore inexpressible:
#
# - **Sheiko, and percentage programming generally**, prices every deadlift variation off the
#   competition deadlift. A paused or deficit pull is written at 70% *of the deadlift*, not of
#   itself.
# - **5/3/1 supplemental work** -- Boring But Big, First Set Last, Widowmakers -- is a
#   percentage of the main lift's training max, and the supplemental movement is often not
#   the main lift.
#
# What it did instead: a Paused Squat at 80% resolved against Paused Squat history, which is
# a different and much lower number, so the prescription came out light in a way that looks
# correct. On a variation never trained it refused to generate outright, which is the more
# visible half of the same gap.
#
# **A pointer per lift rather than a reference per block**, and that is the decision worth
# recording. A block-wide "price everything off this" is simpler and cannot express the
# ordinary case: a block with squat, bench and deadlift main lifts needs each variation
# priced off its *own* competition lift, and one reference per program can only name one of
# the three. The pointer costs a column and expresses all of it.
#
# Nullable, and null means "off its own max" -- which is what every existing row means and
# what most lifts will go on meaning. So this is additive: no row changes behaviour, and the
# generator's fallback is the column being absent rather than a value chosen for it.
#
# No ON DELETE CASCADE, unlike 020's key. That one pointed at a preference *about* a
# movement, so a deleted movement left a preference about nothing. This points at a
# prescription's reference, and a prescription whose reference is deleted is a prescription
# somebody has to look at -- deleting the movement should fail rather than quietly repoint
# the lift at itself and change every load in the block. `rake exercises:merge` moves rows
# across before deleting, and it will need to move these too, which is a task change rather
# than a schema one.
# no_transaction and a concurrent index, following 017, which indexed every other foreign key
# in this schema the same way. CREATE INDEX takes a write lock for its duration and
# CONCURRENTLY does not, which is what keeps a deploy from blocking writes to program_lifts --
# and it cannot run inside a transaction, which is what no_transaction is for.
Sequel.migration do
  no_transaction

  up do
    alter_table(:program_lifts) { add_foreign_key :percent_of_exercise_id, :exercises }
    # #233's rule: a foreign key with no index leading on its column makes the parent's
    # deletes scan this whole table.
    add_index :program_lifts, :percent_of_exercise_id, concurrently: true
  end

  down do
    drop_index :program_lifts, :percent_of_exercise_id, concurrently: true
    alter_table(:program_lifts) { drop_column :percent_of_exercise_id }
  end
end

