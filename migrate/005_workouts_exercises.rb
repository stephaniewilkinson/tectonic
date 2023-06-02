# frozen_string_literal: true

require_relative '../lib/db'
DB.create_join_table(workout_id: :workouts, exercise_id: :exercises)
