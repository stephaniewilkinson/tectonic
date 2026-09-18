# frozen_string_literal: true

# How many warmup sets a lift wants, when the ratio-based default is not what it wants. #451.
#
# The ramp was generated from the top weight alone, through a table of absolute thresholds --
# 136 lb and 96 lb -- and absolute thresholds are the bug. What decides how much ramp a lift
# needs is how far it is from the empty bar, and that is a *ratio*:
#
#     Deadlift    top 150   3.3x the bar   four stops generated
#     Front Squat top 115   2.6x the bar   three stops generated
#     Back Squat  top 235   5.2x the bar   four stops generated
#
# A 150 and a 235 barely differed, when one is three times the bar and the other five. Against
# a 45-minute cap, each unnecessary rung across two or three barbell movements costs five to
# eight minutes -- which is the whole of the budget #446 just gave a lifter.
#
# ## Why this is a column and not only a better algorithm
#
# #451 is unusually careful about the evidence and it is right to be:
#
#   That warming up helps performance is well supported. The specific structure -- how many
#   sets, which rep counts -- is coaching convention, not research. There is no good trial
#   comparing three warmup sets to four. So this should be a configurable default, not a fixed
#   algorithm asserting a right answer.
#
# Replacing one fixed table with a better fixed table would substitute a new convention for
# the old one and go on asserting it. So the arithmetic gets better *and* becomes an answer a
# block can overrule.
#
# ## Nullable, and zero is a real answer
#
# Null means "work it out from the ratio", which is what every lift written so far wants and
# gets. Zero means no ramp at all, which #451 asks for outright -- "let a lift opt out
# entirely; an accessory late in a session following the same pattern rarely needs its own
# ramp" -- and is the reason this is an integer rather than a boolean beside a count.
#
# On the lift rather than on the block, which is where #451 puts the opt-out and is the finer
# of the two. A block-wide count would say the squat and the barbell curl want the same ramp.
Sequel.migration do
  up do
    alter_table(:program_lifts) do
      add_column :warmup_sets, Integer
      # Six is more rungs than any ratio produces and more than anybody ramps through; the
      # ceiling is here so a typo cannot write a session of nothing but warmups. Zero is
      # allowed and means none, which is the point.
      add_constraint(:program_lifts_warmup_sets_in_range) do
        Sequel.lit('warmup_sets IS NULL OR (warmup_sets >= 0 AND warmup_sets <= 6)')
      end
    end
  end

  down do
    alter_table(:program_lifts) do
      drop_constraint(:program_lifts_warmup_sets_in_range)
      drop_column :warmup_sets
    end
  end
end

