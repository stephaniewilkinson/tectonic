# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'program_weeks'
require_relative 'programs'
require_relative 'set_scheme'
require_relative 'sets'
require_relative 'warmup'
require_relative 'workouts'

class Tectonic < Roda
  # Turns a program into real workouts and sets for a given week. A planned
  # session is not a separate kind of record: it is ordinary Set rows written
  # ahead of time with is_completed false, which lifting flips to true.
  class ProgramGenerator
    def initialize(program)
      @program = program
    end

    # Inserts a workout per program day of the numbered week, with every set
    # pre-created, warmups included. Returns that week's workouts, whether generated
    # now or already present. Safe to run twice: see existing_workout.
    #
    # The week is named by its position in the block rather than by a date, because
    # the block's start date already fixes when each of its weeks falls; asking a
    # caller for the right Monday was asking them to recompute what the program knows.
    def generate(number)
      week = @program.week(number)
      raise ArgumentError, "Program #{@program.id} has no week #{number}; it has #{@program.weeks}." unless week

      DB.transaction do
        week.program_days.sort_by(&:weekday).map { |day| generate_day(day, week.date_for(day.weekday)) }
      end
    end

    private

    def generate_day(day, date)
      existing = existing_workout(date)
      return existing if existing

      workout = Workout.create(account_id: @program.account_id, date:)
      day.program_lifts.sort_by(&:position).each { |lift| insert_sets(workout, lift) }
      workout
    end

    # Idempotency on (account_id, date). A day that already has a workout is left
    # exactly as it is, so regenerating a week never duplicates sets and never
    # overwrites what was actually lifted. Matched across the whole day because
    # workouts.date is a timestamp, so equality on a bare date would never hit.
    def existing_workout(date)
      Workout.where(account_id: @program.account_id, date: date...(date + 1)).first
    end

    def insert_sets(workout, lift)
      Warmup.ramp(lift.top_weight, is_barbell: lift.is_barbell).each do |set|
        insert_set(workout, lift, set, is_warmup: true)
      end
      working_sets(lift).each { |set| insert_set(workout, lift, set, is_warmup: false) }
    end

    # Rep conversion is a main-work preference: accessories keep the reps they
    # were prescribed, so they are generated as if the program had no preference.
    def working_sets(lift)
      SetScheme.working_sets(
        sets: lift.sets,
        reps: lift.reps,
        top_weight: lift.top_weight,
        preferred_reps: (@program.preferred_reps if lift.is_main),
        is_ascending: @program.is_ascending
      )
    end

    # Weight and reps start out equal to the planned values. Lifting the set as
    # written only flips is_completed; lifting it differently changes weight or
    # reps and leaves the planned columns behind as the record of the prescription.
    def insert_set(workout, lift, set, is_warmup:)
      Set.insert(
        workout_id: workout.id, exercise_id: lift.exercise_id,
        weight: set[:weight], reps: set[:reps],
        planned_weight: set[:weight], planned_reps: set[:reps],
        is_warmup:, is_completed: false, is_barbell: lift.is_barbell
      )
    end
  end
end

