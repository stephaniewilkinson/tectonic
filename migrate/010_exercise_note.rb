# frozen_string_literal: true

# Why a movement is in the program, in the lifter's own words: "this helps correct
# valgus", "keep the ribs down", "brace before you unrack". A cue like that is true of
# the movement every time it is done, not of one Tuesday's third set, so it goes beside
# the name rather than on `sets`. `program_lifts` already carries a `note`, and that one
# answers a different question -- what this block wants from this prescription, which
# changes when the block does, where the cue does not.
#
# Nullable and with no default, because "nothing written" needs exactly one spelling.
# An empty string and a null both mean it, and they read differently afterwards: '' is
# truthy in Ruby, so a blank note would draw its own empty paragraph on the movement's
# page forever. Null is the one a reader can test for, so it is the one that is stored,
# and Exercise.clean_note is what every write path goes through to say so.
#
# There is deliberately no per-account note on a library movement. A library row has a
# nil account_id and appears on every account's page, so a note column on one is a value
# one account writes and every other account reads. Per-account notes on shared
# movements are a join table -- account_id, exercise_id, note -- not a column, and that
# is a bigger change than this one. Nothing is blocked on it in the meantime: the
# exercise form will create a movement of your own under any name, including a name the
# library already uses, and a movement of your own is notable.
Sequel.migration do
  up do
    add_column :exercises, :note, String, text: true
  end

  down do
    drop_column :exercises, :note
  end
end

