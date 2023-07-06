# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.create_table(:sets) do
  primary_key :id
  foreign_key :exercise_id, :exercises, null: false
  foreign_key :workout_id, :workouts, null: false
  TrueClass :is_completed, default: false
  TrueClass :is_warmup, { default: false, null: false }
  Integer :reps, null: false
  Integer :weight, null: false
end
