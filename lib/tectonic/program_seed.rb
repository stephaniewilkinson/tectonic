# frozen_string_literal: true

require 'date'
require_relative 'db'
require_relative 'exercises'
# Exercise.barbell_by_name?, the default a movement the seed has to create comes out with.
require_relative 'exercise_library'
require_relative 'program_days'
require_relative 'program_lifts'
require_relative 'program_weeks'
require_relative 'programs'

class Tectonic < Roda
  # A program written as a Ruby hash, until there is a UI for editing one.
  module ProgramSeed
    # Block 0, one written week. Weeks are a list rather than a scalar because the
    # block is the unit now: adding week 2 here is adding an entry, not writing a
    # second program that then has to be remembered as related to this one.
    BLOCK_0 = {
      name: 'Block 0',
      block: 0,
      preferred_reps: 3,
      is_ascending: true,
      weeks: [
        {
          number: 1,
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
        }
      ]
    }.freeze

    module_function

    # Creates the program, its weeks, days and lifts, creating any exercise it names
    # that the account does not have yet. Returns the existing program untouched if the
    # block is already seeded: the key is the block rather than the block and a week,
    # because a week is no longer a program of its own.
    def seed(account_id, attributes = BLOCK_0, start_date: monday_of_this_week)
      key = { account_id:, name: attributes[:name], block: attributes[:block] }
      existing = Program.where(key).first
      return existing if existing

      DB.transaction do
        program = Program.create(**key, start_date:, notes: attributes[:notes],
                                        preferred_reps: attributes[:preferred_reps],
                                        is_ascending: attributes[:is_ascending])
        attributes[:weeks].each { |week| seed_week(program, account_id, week) }
        program
      end
    end

    def seed_week(program, account_id, attributes)
      week = ProgramWeek.create(program_id: program.id, number: attributes[:number],
                                is_deload: attributes.fetch(:is_deload, false), notes: attributes[:notes])
      attributes[:days].each { |day| seed_day(week, account_id, day) }
    end

    def seed_day(week, account_id, attributes)
      day = ProgramDay.create(program_week_id: week.id, weekday: attributes[:weekday], focus: attributes[:focus])
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

    # A movement the seed names but the account does not have yet is created here, and is
    # a barbell movement when the library knows the name -- the same default every path
    # with nobody to ask uses.
    def exercise_id(account_id, name)
      Exercise.where(account_id:, name:).first&.id ||
        Exercise.insert(account_id:, name:, is_barbell: Exercise.barbell_by_name?(name))
    end

    # A seeded block opens on the Monday of the week it is seeded in, so the week it
    # writes is the one about to be trained rather than one already in the past.
    def monday_of_this_week(today = Date.today)
      today - ((today.wday - 1) % 7)
    end
  end
end

