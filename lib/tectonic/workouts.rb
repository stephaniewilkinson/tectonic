# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'oauth_application'
require_relative 'program_days'

class Tectonic < Roda
  class Workout < Sequel::Model
    one_to_many :sets
    # The program day this workout was generated from, nil for one logged by hand or
    # over MCP. That null is the whole distinction between a plan and a record of
    # training, so every reading of "is this a planned session" starts here.
    many_to_one :program_day
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    dataset_module do
      # Answers "has anything been lifted here" for every row of a list in the one
      # query that fetches it, as a correlated EXISTS rather than a join, so a page of
      # workouts stays one query and no row's set rows are loaded to find out.
      def with_performance
        lifted = db[:sets].where(workout_id: Sequel[:workouts][:id], is_completed: true)
        select_all(:workouts).select_append(lifted.exists.as(:is_performed))
      end
    end

    # Whether any set has been lifted, which is what separates a session that happened
    # from one that was only written. Taken from the row when the list already asked
    # (with_performance), and otherwise one EXISTS of its own.
    def performed?
      values.fetch(:is_performed) { sets_dataset.where(is_completed: true).limit(1).any? }
    end

    # Planned, performed or skipped, decided without inspecting the sets one at a time.
    # A session that has been lifted at all is performed; a generated one still on or
    # ahead of its date is planned, and one whose date has passed with nothing lifted
    # was skipped. A workout typed in by hand is never skipped: it exists because a
    # person logged it, so once its day is over it reads as history whether or not
    # anything in it was ticked off.
    #
    # Today is not over, which is what the >= on the last line is for. The day is still
    # running, and a session with nothing lifted in it yet is one you are about to do
    # rather than a record of having done it. With > it fell through to performed and
    # the index filed today's session under History, below every session still to come
    # -- the row a lifter opened the page to start. A generated session dated today was
    # never affected either way: program_day_id makes it a plan before any date is
    # compared.
    def status(today = Date.today)
      return :performed if performed?
      return :skipped if program_day_id && date.to_date < today
      return :planned if program_day_id || date.to_date >= today

      :performed
    end

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
end

