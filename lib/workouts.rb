# frozen_string_literal: true

require_relative 'db'

class Workout < Sequel::Model
  one_to_many :xsets

  # def self.create_workout_a(account_id, squat_weight, benchpress_weight, row_weight)
  #   workout_id = Workout.insert(account_id:, date: Time.now.utc)
  #   workout = Workout.where(id: workout_id).first

  #   exercise_id = Exercise.insert(goal_weight: squat_weight, name: 'Squat')
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: squat_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: squat_weight, reps: 5)

  #   exercise_id = Exercise.insert(goal_weight: benchpress_weight, name: 'Benchpress') #=> 42
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: benchpress_weight, reps: 5)

  #   exercise_id = Exercise.insert(goal_weight: row_weight, name: 'Row')
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: row_weight, reps: 8)
  #   SETS.insert(exercise_id:, weight: row_weight, reps: 8)
  #   SETS.insert(exercise_id:, weight: row_weight, reps: 8)
  #   workout_id
  # end

  # def self.create_workout_b(account_id, deadlift_weight, ohp_weight, pulldown_weight)
  #   workout_id = Workout.insert(account_id:, date: Time.now.utc)
  #   workout = Workout.where(id: workout_id).first

  #   exercise_id = Exercise.insert(goal_weight: deadlift_weight, name: 'Deadlift')
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: deadlift_weight, reps: 5)

  #   exercise_id = Exercise.insert(goal_weight: ohp_weight, name: 'Overhead press')
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)
  #   SETS.insert(exercise_id:, weight: ohp_weight, reps: 5)

  #   exercise_id = Exercise.insert(goal_weight: pulldown_weight, name: 'Lat pulldown')
  #   Exercise.where(id: exercise_id).first.add_workout(workout)
  #   SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
  #   SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
  #   SETS.insert(exercise_id:, weight: pulldown_weight, reps: 8)
  #   workout_id
  # end
end
