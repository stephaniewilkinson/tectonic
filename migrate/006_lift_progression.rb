# frozen_string_literal: true

# A prescribed load was a literal written once and never recalculated, so week two of a
# block asked for exactly what week one had asked for however the lifting had gone. What
# was missing was not the arithmetic -- the RPE chart and the estimated max were already
# here -- but somewhere for a lift to say how its load is meant to move. This is that
# column, and it holds one of three rules:
#
# fixed    the written top_weight, every week, for a lift that is not meant to climb
# linear   the written top_weight to start, and thereafter derived from what was actually
#          lifted last time the movement came round
# percent  percent_of_max of the account's estimated max for the movement, read fresh at
#          generation, so the load tracks demonstrated strength without any step rule
#
# The rule lives here rather than being inferred from which of top_weight and
# percent_of_max happens to be filled in. Inference gave two rules where three were needed
# and no way at all to say "hold this one still", and it made the answer to "how does this
# lift progress" a thing you worked out from the absence of a value rather than read.
#
# Existing rows adopt the rule they were already being generated under: a lift written as
# a percentage keeps being one, and everything else becomes linear rather than fixed,
# because a load that never moves is what this issue is about and a block already in
# progress is better served climbing. A check constraint spells the three values out in
# the schema, which is the only place a typo in a rule name would otherwise surface as a
# lift silently not progressing.
Sequel.migration do
  up do
    add_column :program_lifts, :progression, String, null: false, default: 'linear'
    from(:program_lifts).exclude(percent_of_max: nil).update(progression: 'percent')
    alter_table(:program_lifts) do
      add_constraint(:program_lifts_progression_known) { progression =~ %w[fixed linear percent] }
    end
  end

  down do
    drop_column :program_lifts, :progression
  end
end

