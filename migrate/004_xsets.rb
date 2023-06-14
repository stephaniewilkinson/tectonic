# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:xsets) do
  primary_key :id
  foreign_key :exercise_id, :exercises, null: false
  foreign_key :workout_id, :workouts, null: false
  TrueClass :is_completed, { default: false }
  Integer :reps # Benchpress
  Integer :weight
end
