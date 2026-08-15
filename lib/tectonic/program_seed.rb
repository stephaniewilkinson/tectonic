# frozen_string_literal: true

require_relative 'db'
require_relative 'exercises'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'programs'

class Tectonic < Roda
  # A program written as a Ruby hash, until there is a UI for editing one.
  module ProgramSeed
    # Monday of block 0, week 1.
    BLOCK_0_WEEK_1 = {
      name: 'Block 0',
      block: 0,
      week: 1,
      preferred_reps: 3,
      is_ascending: true,
      days: [
        {
          weekday: 1,
          focus: 'Squat',
          lifts: [
            { exercise: 'Back Squat', sets: 4, reps: 5, top_weight: 155, is_barbell: true, is_main: true },
            { exercise: 'Decline Paused Bench', sets: 3, reps: 8, top_weight: 105, is_barbell: true },
            { exercise: 'Glute Press Machine', sets: 3, reps: 10, top_weight: 135 },
            { exercise: 'Heel-Elevated Paused Squat', sets: 3, reps: 5, top_weight: 120, is_barbell: true },
            { exercise: 'Barbell Good Morning', sets: 3, reps: 8, top_weight: 75, is_barbell: true }
          ]
        }
      ]
    }.freeze

    module_function

    # Creates the program, its days and its lifts, creating any exercise it names
    # that the account does not have yet. Returns the existing program untouched
    # if this block and week are already seeded.
    def seed(account_id, attributes = BLOCK_0_WEEK_1)
      key = { account_id:, name: attributes[:name], block: attributes[:block], week: attributes[:week] }
      existing = Program.where(key).first
      return existing if existing

      DB.transaction do
        program = Program.create(**key, notes: attributes[:notes], preferred_reps: attributes[:preferred_reps],
                                        is_ascending: attributes[:is_ascending])
        attributes[:days].each { |day| seed_day(program, account_id, day) }
        program
      end
    end

    def seed_day(program, account_id, attributes)
      day = ProgramDay.create(program_id: program.id, weekday: attributes[:weekday], focus: attributes[:focus])
      attributes[:lifts].each_with_index { |lift, position| seed_lift(day, account_id, lift, position) }
    end

    # Position is the order the lift was written in, which is the order it will be
    # generated and the order it will appear in the session.
    def seed_lift(day, account_id, lift, position)
      ProgramLift.create(
        program_day_id: day.id, exercise_id: exercise_id(account_id, lift[:exercise]),
        position:, sets: lift[:sets], reps: lift[:reps], top_weight: lift[:top_weight],
        is_barbell: lift.fetch(:is_barbell, false), is_main: lift.fetch(:is_main, false)
      )
    end

    def exercise_id(account_id, name)
      Exercise.where(account_id:, name:).first&.id || Exercise.insert(account_id:, name:)
    end
  end
end