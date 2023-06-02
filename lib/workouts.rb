# frozen_string_literal: true

require_relative 'db'

module Workouts
  SETS = DB[:sets]
  WORKOUTS = DB[:workouts]
  EXERCISES = DB[:exercises]

  module_function

  def create_workout_a(account_id, squat_weight, benchpress_weight, row_weight)
    workout_id = WORKOUTS.insert(account_id:, date: Time.now.utc)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: squat_weight, name: 'Squat')
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
    SETS.insert(exercise_id:, weight: squat_weight, reps: 5)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: benchpress_weight, name: 'Benchpress')
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
    SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: row_weight, name: 'Row')
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    SETS.insert(exercise_id:, weight: row_weight, reps: 8)
    workout_id
  end

  def create_workout_b(account_id, deadlift_weight, ohp_weight, pulldown_weight)
    workout_id = WORKOUTS.insert(account_id:, date: Time.now.utc)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: deadlift_weight, name: 'Deadlift')
    SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)
    SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)
    SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: ohp_weight, name: 'Overhead press')
    SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)
    SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)
    SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)

    exercise_id = EXERCISES.insert(workout_id:, goal_weight: pulldown_weight, name: 'Lat pulldown')
    SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
    SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
    SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
    workout_id
  end

end
