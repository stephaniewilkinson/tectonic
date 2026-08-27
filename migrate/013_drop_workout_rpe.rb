# frozen_string_literal: true

# The session rating goes, and the column with it. #209.
#
# A workout carried one rating for the whole session, asked at the foot of the session
# screen: "how hard was the whole session?". Per-set rating (#175) answers the same
# question better and at the grain the answer actually has -- five lifts in a session are
# five different questions, and one number averaged across a heavy squat and an easy row
# describes neither. Nothing read this column except the tool that wrote it and a clause
# in the MCP headline, so it was a number collected and then handed back.
#
# Dropped rather than left in place, which was a decision rather than tidiness. #197 is
# about columns whose feature was never built, and the answer there is to build the half
# that is missing. This is the opposite case: the feature existed and is being removed on
# purpose, so keeping the column would keep the residue of a decision already made, and
# would put this row straight onto #197's list.
#
# Worth being plain about the cost: **any session rating already recorded is deleted by
# this and the down migration cannot bring it back.** Rolling back restores the column,
# empty. The per-set ratings on `sets.rpe` are untouched -- a different column, a
# different feature, and the one that survives.
Sequel.migration do
  up do
    drop_column :workouts, :rpe
  end

  down do
    add_column :workouts, :rpe, Integer
  end
end

