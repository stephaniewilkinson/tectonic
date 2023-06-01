# frozen_string_literal: true

require_relative 'db'

module Workouts
  SETS = DB[:sets]
  WORKOUTS = DB[:workouts]
  EXERCISES = DB[:exercises]

  module_function

  def create_workout_a(user_id, squat_weight, benchpress_weight, row_weight)
    workout_id = WORKOUTS.insert(user_id:, date: Time.now.utc)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: squat_weight, name: 'Squat')
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: benchpress_weight, name: 'Benchpress')
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 8)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 8)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 8)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: row_weight, name: 'Row')
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    workout_id
  end
end
