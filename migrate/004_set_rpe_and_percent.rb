# frozen_string_literal: true

# The only effort rating in the schema was one integer for a whole session, so a session
# holding five different lifts had one number to describe all of them and nothing could
# say which lift was the hard one. Effort is a property of the set it describes -- the
# app's own guidance says to rate it before you rack it, because the number decays within
# seconds -- so sets.rpe is where it belongs, alongside the session rating rather than
# instead of it: how the whole session felt is a different question from how one set did.
#
# program_lifts.percent_of_max lets a lift be written as a percentage of the estimated max
# for its movement instead of an absolute load, which is how strength blocks are usually
# written and what an assistant reaches for first. top_weight becomes nullable for exactly
# that case: a lift written as a percentage has no pounds to record until the week is
# generated and the max is read.
#
# Down cannot turn a percentage back into pounds -- nothing in the schema holds the max it
# was a percentage of -- so it fills a null top_weight with 0 as a placeholder before the
# constraint returns. In practice there are none to fill: the column is nullable only for
# rows written after this runs.
Sequel.migration do
  up do
    add_column :sets, :rpe, Integer
    add_column :program_lifts, :percent_of_max, Integer
    alter_table(:program_lifts) { set_column_allow_null :top_weight }
  end

  down do
    from(:program_lifts).where(top_weight: nil).update(top_weight: 0)
    alter_table(:program_lifts) { set_column_not_null :top_weight }
    drop_column :program_lifts, :percent_of_max
    drop_column :sets, :rpe
  end
end

