# frozen_string_literal: true

# How a movement is actually done. Three facts, and they are independent of one another:
# whether it carries weight, whether it is counted in reps or in time, and whether that
# count is per side or for both together. Eight combinations, all real -- a plank is
# unweighted time, a weighted plank is weighted time, a Bulgarian split squat is weighted
# reps per side, a side plank is unweighted time per side.
#
# None of the three was expressible. `reps` was the only quantity column, so a 35-minute
# walk was stored as 35 reps and `Volume` summed it as reps of lifting, and a lift done 8
# per side was stored as 8, which is half the work that happened.
#
# 008 put the first of the three on `progression`, as a fourth value beside linear,
# percent and fixed. That was the wrong home and this moves it. `progression` answers how
# a load changes from week to week; whether there is a load at all is a different
# question, and answering both in one column meant `unloaded` had to stand in for "there
# is nothing here to progress". Weighted is now its own column beside the other two, and
# `progression` is null exactly when there is no load to decide -- so the two cannot
# disagree, which was the only thing the single column bought.
#
# The default lives on the exercise and the choice lives on the prescription: a movement
# has a usual way and a particular block may want another. That is the shape `is_barbell`
# already has, where the writer takes the movement's answer unless the caller gives one.
module ExerciseShape
  MEASURED = %i[program_lifts sets].freeze
  # Only the unambiguous names. A "Lunge" or a "Step-Up" is counted both ways by
  # different people and is left alone rather than silently doubled: a wrong guess changes
  # what every past volume figure means, where leaving it alone is an error somebody can
  # see and correct. Spelled as a plain array rather than %w, which splits on the spaces
  # inside these and once matched "Never Done" against a stray "%one".
  PER_SIDE = [
    '%bulgarian%', '%single-arm%', '%single arm%', '%one-arm%', '%one arm%',
    '%single-leg%', '%single leg%', '%pistol%', '%per side%'
  ].freeze

  module_function

  def add_columns(db)
    db.alter_table(:exercises) do
      add_column :default_measure, String, null: false, default: 'reps'
      add_column :default_is_per_side, TrueClass, null: false, default: false
      add_column :default_is_weighted, TrueClass, null: false, default: true
      add_constraint(:exercises_measure_known) { default_measure =~ %w[reps time] }
    end
    MEASURED.each { |table| measure_columns(db, table) }
  end

  # A timed set has no rep count, so the column that was always required stops being so.
  # The second constraint is what keeps that from meaning "no quantity at all": exactly
  # one, and it is the one the measure names, or every reader has to decide which of two
  # numbers to believe.
  def measure_columns(db, table)
    db.alter_table(table) do
      add_column :measure, String, null: false, default: 'reps'
      add_column :is_per_side, TrueClass, null: false, default: false
      add_column :duration_seconds, Integer
      set_column_allow_null :reps
      add_constraint(:"#{table}_measure_known") { measure =~ %w[reps time] }
      add_constraint(:"#{table}_measures_one_way") { Sequel.lit(ExerciseShape.one_way) }
    end
  end

  def one_way
    "(measure = 'reps' AND reps IS NOT NULL AND duration_seconds IS NULL) OR " \
      "(measure = 'time' AND duration_seconds IS NOT NULL AND reps IS NULL)"
  end

  # Weight moves off progression and onto its own column, and progression goes null where
  # there is no load to decide -- which is what makes the two agree by construction rather
  # than by a rule somebody has to remember.
  def split_weight_from_progression(db)
    db.add_column :program_lifts, :is_weighted, TrueClass, null: false, default: true
    db[:program_lifts].where(progression: 'unloaded').update(is_weighted: false)
    db.alter_table(:program_lifts) do
      drop_constraint(:unloaded_lifts_carry_no_load)
      drop_constraint(:program_lifts_progression_known)
      set_column_allow_null :progression
    end
    db[:program_lifts].where(is_weighted: false).update(progression: nil)
    reconstrain_progression(db)
  end

  def reconstrain_progression(db)
    db.alter_table(:program_lifts) do
      add_constraint(:program_lifts_progression_known) { Sequel.lit(ExerciseShape.known_rules) }
      add_constraint(:program_lifts_weight_matches_progression) { Sequel.lit(ExerciseShape.weight_agrees) }
    end
  end

  def known_rules
    "progression IS NULL OR progression IN ('fixed', 'linear', 'percent')"
  end

  def weight_agrees
    'is_weighted = (progression IS NOT NULL) AND ' \
      '(is_weighted OR (top_weight IS NULL AND percent_of_max IS NULL))'
  end

  # Existing rows are all rep-counted, which is how they were being read, so the column
  # defaults already describe them. Per side is the one thing that has to be guessed, and
  # it is worth being plain: no row recorded whether it was per side, so this reads the
  # exercise name and nothing else.
  def infer_per_side(db)
    PER_SIDE.each { |pattern| db[:exercises].where(Sequel.ilike(:name, pattern)).update(default_is_per_side: true) }
  end

  def restore_progression(db)
    db.alter_table(:program_lifts) do
      drop_constraint(:program_lifts_weight_matches_progression)
      drop_constraint(:program_lifts_progression_known)
    end
    db[:program_lifts].where(is_weighted: false).update(progression: 'unloaded')
    refold_weight_into_progression(db)
  end

  def refold_weight_into_progression(db)
    db.alter_table(:program_lifts) do
      set_column_not_null :progression
      add_constraint(:program_lifts_progression_known) { progression =~ %w[fixed linear percent unloaded] }
      add_constraint(:unloaded_lifts_carry_no_load) { Sequel.lit(ExerciseShape.carries_no_load) }
      drop_column :is_weighted
    end
  end

  def carries_no_load
    "progression <> 'unloaded' OR (top_weight IS NULL AND percent_of_max IS NULL)"
  end

  # A timed row has no reps to go back to, so it cannot survive the column becoming
  # required again; those rows go rather than being given an invented rep count.
  def drop_columns(db)
    MEASURED.each { |table| drop_measure_columns(db, table) }
    db.alter_table(:exercises) do
      drop_constraint(:exercises_measure_known)
      drop_column :default_measure
      drop_column :default_is_per_side
      drop_column :default_is_weighted
    end
  end

  def drop_measure_columns(db, table)
    db.alter_table(table) do
      drop_constraint(:"#{table}_measures_one_way")
      drop_constraint(:"#{table}_measure_known")
    end
    db[table].where(measure: 'time').delete
    db.alter_table(table) do
      %i[measure is_per_side duration_seconds].each { |column| drop_column column }
      set_column_not_null :reps
    end
  end
end

Sequel.migration do
  up do
    ExerciseShape.add_columns(self)
    ExerciseShape.split_weight_from_progression(self)
    ExerciseShape.infer_per_side(self)
  end

  down do
    ExerciseShape.restore_progression(self)
    ExerciseShape.drop_columns(self)
  end
end

