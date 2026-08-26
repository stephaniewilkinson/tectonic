# frozen_string_literal: true

# Weights stop being whole numbers.
#
# 1.25 lb pairs are ordinary equipment and make a 2.5 lb jump, which is the smallest
# useful step for an upper-body lift that has stalled; most machine stacks are not built
# in whole pounds; and 20 kg is 44.0925 lb, so the app cannot leave pounds while these
# columns are integers. #132 chose step="1" over step="any" on every weight input for
# exactly this reason -- letting a browser accept 137.5 meant it was truncated on the way
# in and the lifter was told 137 without being told why, and silently losing the half
# pound is worse than refusing it.
#
# numeric(7, 2) rather than a float. A weight is a decimal quantity that gets compared and
# summed -- Volume totals tonnage across a season and Progression compares a lifted weight
# against a prescribed one -- and binary floating point cannot represent 137.5 + 2.5
# reliably enough to be equal to anything. Postgres numeric is exact.
#
# Two decimal places, which covers 1.25s and 0.25 kg conversion and stops well short of
# pretending a bar can be loaded to a thousandth. Seven digits leaves 99999.99, which is
# more than any bar holds and more than any stack goes to.
#
# The backfill is nothing: every integer is already an exact decimal, so Postgres widens
# the column in place and no row changes value. Rolling back is the lossy direction --
# `down` rounds, because an integer column cannot hold 137.5 and refusing to roll back at
# all would leave a database that cannot be stepped down past this point.
Sequel.migration do
  up do
    alter_table(:sets) do
      set_column_type :weight, 'numeric(7, 2)'
      set_column_type :planned_weight, 'numeric(7, 2)'
    end
    alter_table(:program_lifts) { set_column_type :top_weight, 'numeric(7, 2)' }
  end

  down do
    alter_table(:sets) do
      set_column_type :weight, Integer, using: Sequel.lit('round(weight)::integer')
      set_column_type :planned_weight, Integer, using: Sequel.lit('round(planned_weight)::integer')
    end
    alter_table(:program_lifts) do
      set_column_type :top_weight, Integer, using: Sequel.lit('round(top_weight)::integer')
    end
  end
end

