# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:sets) do
  primary_key :id
  foreign_key :exercise_id, :exercises
  Integer :reps # Benchpress
  Integer :weight
end
