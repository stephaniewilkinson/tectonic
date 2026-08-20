# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'program_weeks'
require_relative 'programs'
require_relative 'rounding'
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
      existing = existing_workout(day, date)
      return existing if existing

      workout = Workout.create(account_id: @program.account_id, date:, program_day_id: day.id)
      day.program_lifts.sort_by(&:position).each { |lift| insert_sets(workout, lift) }
      workout
    end

    # Idempotency on (account_id, program day, date): the workout this day already wrote
    # for this date is left exactly as it is, so regenerating a week never duplicates
    # sets and never overwrites what was lifted. Keying on the date alone conflated two
    # different things -- any workout logged that day silently stood in for this day's
    # session, and the generator could not recognise its own output as its own. Matched
    # across the whole day because workouts.date is a timestamp, so equality on a bare
    # date would never hit.
    def existing_workout(day, date)
      Workout.where(account_id: @program.account_id, program_day_id: day.id,
                    date: date...(date + 1)).first
    end

    def insert_sets(workout, lift)
      top = top_weight(lift)
      Warmup.ramp(top, is_barbell: lift.is_barbell).each do |set|
        insert_set(workout, lift, set, is_warmup: true)
      end
      working_sets(lift, top).each { |set| insert_set(workout, lift, set, is_warmup: false) }
    end

    # The load the lift is written at: pounds when it says pounds, and otherwise a
    # percentage of what the account's own lifting says its max is today. A percentage is
    # resolved at generation rather than stored, so a week written months ago is generated
    # against the strength that exists when it is trained. With no completed set the chart
    # can read there is no max to take a percentage of, and inventing one would write a
    # whole week of loads off a guess, so the week refuses to generate and says which
    # movement is missing.
    def top_weight(lift)
      return lift.top_weight if lift.top_weight

      exercise = Exercise[lift.exercise_id]
      max = exercise.estimated_max(account_id: @program.account_id)
      unless max
        raise ArgumentError, "No estimated max for #{exercise.name} yet, so #{lift.percent_of_max}% of it " \
                             'cannot be worked out. Log a completed set of it first.'
      end

      Rounding.to_increment(max * lift.percent_of_max / 100.0)
    end

    # Rep conversion is a main-work preference: accessories keep the reps they
    # were prescribed, so they are generated as if the program had no preference.
    def working_sets(lift, top)
      SetScheme.working_sets(
        sets: lift.sets,
        reps: lift.reps,
        top_weight: top,
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

