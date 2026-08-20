# frozen_string_literal: true

# Whether a movement is loaded on a bar decides whether its sets get plate math and a
# warmup ramp, and until now it was answered by matching the movement's name against the
# fifty-four names in the built-in library. That was right for every movement the library
# names and wrong for everything else: a lifter's own "Front Squat Variation", or anything
# an assistant invented, could never be a barbell lift however it was written. The answer
# belongs on the row, so here it is.
#
# The names are written out here rather than read from lib/tectonic/exercise_library.rb on
# purpose. A migration records what was true when it ran; the library is free to grow
# afterwards, and a backfill that changed with it would mean two databases migrated a
# month apart came out differently.
BARBELL_LIBRARY_AT_005 = [
  'Back Squat', 'Bench Press', 'Deadlift', 'Front Squat', 'High-Bar Squat', 'Low-Bar Squat',
  'Pause Squat', 'Box Squat', 'Heel-Elevated Squat', 'Tempo Squat', 'Anderson Squat',
  'Safety Bar Squat', 'Zercher Squat', 'Overhead Squat', 'Sumo Deadlift', 'Deficit Deadlift',
  'Block Pull', 'Rack Pull', 'Paused Deadlift', 'Romanian Deadlift', 'Stiff-Leg Deadlift',
  'Snatch-Grip Deadlift', 'Trap Bar Deadlift', 'Good Morning', 'Barbell Hip Thrust',
  'Barbell Glute Bridge', 'Close-Grip Bench Press', 'Wide-Grip Bench Press',
  'Incline Bench Press', 'Decline Bench Press', 'Paused Bench Press', 'Tempo Bench Press',
  'Spoto Press', 'Larsen Press', 'Floor Press', 'Pin Press', 'Board Press', 'Overhead Press',
  'Seated Overhead Press', 'Push Press', 'Z Press', 'Bent Over Row', 'Pendlay Row',
  'Yates Row', 'Landmine Row', 'Barbell Shrug', 'Barbell Curl', 'Barbell Skull Crusher',
  'Power Clean', 'Hang Clean', 'Clean Pull', 'Power Snatch', 'Snatch Pull', 'Push Jerk'
].freeze

Sequel.migration do
  # Matched case-insensitively on the name, so an account's own row spelled the way the
  # library spells it comes out true as well -- which is exactly what the method being
  # replaced did, so no existing set changes how it renders.
  up do
    add_column :exercises, :is_barbell, TrueClass, null: false, default: false
    folded = BARBELL_LIBRARY_AT_005.map(&:downcase)
    from(:exercises).where { Sequel.function(:lower, :name) =~ folded }.update(is_barbell: true)
  end

  down do
    drop_column :exercises, :is_barbell
  end
end

