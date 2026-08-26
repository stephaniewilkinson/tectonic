# frozen_string_literal: true

# What a session was, in the lifter's own words: "morning lift", "evening walk", "squat
# day". #89 asked for two workouts on one date and #133 proved with specs that they
# already work end to end; what neither gave anybody is a way to tell the two apart. A
# workout carried id, account_id, photo, date, created_on, rpe and the two provenance
# columns, and nothing that says what it was, so the morning lift and the evening walk
# rendered as the same word twice in one calendar cell and the same date twice in the
# list.
#
# On `workouts` rather than on the program that wrote one, because a workout logged by
# hand is the case that needs it most: a generated session can take its name from the
# program day's focus, and a walk somebody logged on a Tuesday has no program behind it
# at all.
#
# Nullable and with no default, following exercises.note: "nothing written" needs exactly
# one spelling, and a form posts an empty string whether or not anyone typed in it. ''
# is truthy in Ruby, so a blank name would draw its own empty element beside every date
# forever. Null is the one a reader can test for, so Workout.clean_name is what every
# write path goes through to produce it.
#
# No length limit and no uniqueness. Two sessions can honestly be called "squat day", and
# they are told apart by their dates; a name is a label, not a key.
Sequel.migration do
  up do
    add_column :workouts, :name, String
  end

  down do
    drop_column :workouts, :name
  end
end

