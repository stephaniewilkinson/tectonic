# frozen_string_literal: true

require 'date'
require_relative '../tool'
# ProgramSeed.monday_of_this_week: the rule for where a block starts when nobody says
# lives with the seeded program, and one definition of it beats two that can disagree.
require_relative '../../program_seed'
require_relative 'program_support'
require_relative 'program_writer'

class Tectonic < Roda
  module MCP
    module Tools
      # Writes a whole training block in one call: the block, its weeks, the days in each
      # week and every lift of every day.
      #
      # Coarse on purpose. A four-week block of four training days is sixty-odd lifts, and
      # composing that from one call per lift is sixty round trips in which a model can
      # lose its place, half-write a plan, and leave a lifter with three days of week two
      # and nothing else. A block written in one call either exists or does not. The fine
      # tools beside this one are for changing a plan that already exists, which is where
      # per-object calls are the right size.
      class CreateProgram < Tool
        LIFT = {
          type: 'object',
          properties: {
            exercise: { type: 'string' }, sets: { type: 'integer' }, reps: { type: 'integer' },
            top_weight: { type: 'number' }, percent_of_max: { type: 'integer' },
            is_weighted: { type: 'boolean' }, measure: { type: 'string', enum: %w[reps time] },
            is_per_side: { type: 'boolean' }, duration_seconds: { type: 'integer' },
            is_main: { type: 'boolean' }, is_barbell: { type: 'boolean' }, note: { type: 'string' }
          },
          required: %w[exercise sets], additionalProperties: false
        }.freeze
        DAY = {
          type: 'object',
          properties: { weekday: { type: 'integer' }, focus: { type: 'string' },
                        lifts: { type: 'array', items: LIFT } },
          required: %w[weekday], additionalProperties: false
        }.freeze
        WEEK = {
          type: 'object',
          properties: { number: { type: 'integer' }, is_deload: { type: 'boolean' },
                        notes: { type: 'string' }, days: { type: 'array', items: DAY } },
          required: [], additionalProperties: false
        }.freeze

        tool_name 'create_program'
        description 'Write a whole training block: its weeks, the days in each week (0 is ' \
                    'Sunday, 6 is Saturday) and the lifts of each day, in one call. Each ' \
                    'lift gives either top_weight in pounds or percent_of_max, or ' \
                    'is_weighted false for work carrying no external load; measure is ' \
                    'reps or time, and a timed lift gives duration_seconds. start_date ' \
                    'defaults to the Monday of the current week; weeks are numbered by ' \
                    'their position unless numbered explicitly.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            name: { type: 'string' }, block: { type: 'integer' }, start_date: { type: 'string' },
            notes: { type: 'string' }, preferred_reps: { type: 'integer' },
            is_ascending: { type: 'boolean' }, weeks: { type: 'array', items: WEEK }
          },
          required: %w[name weeks], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          program = write(context, arguments)
          ok("Wrote #{program.name}: #{program.weeks} week(s) from #{program.start_date}, " \
             "#{lift_count(program)} lift(s).", structured: ProgramView.full_program(program))
        end

        # One transaction: a block that fails halfway leaves nothing behind, because half
        # a plan is worse than none and a model cannot tell which half it got.
        def self.write(context, arguments)
          refuse_duplicate(context, arguments)
          DB.transaction do
            program = Program.create(account_id: context.account_id, name: arguments[:name].to_s.strip,
                                     block: arguments[:block], notes: arguments[:notes],
                                     start_date: start_date(arguments), preferred_reps: arguments[:preferred_reps],
                                     is_ascending: arguments.fetch(:is_ascending, true))
            arguments[:weeks].each_with_index { |week, index| ProgramWriter.week(context, program, week, index + 1) }
            program
          end
        end

        # A block is identified by its name and number, which is how a lifter refers to
        # one, so writing a second block by the same name is far more likely to be a model
        # repeating itself than a deliberate duplicate. It is refused with the id of the
        # block already there, which is also what the edit tools need.
        def self.refuse_duplicate(context, arguments)
          existing = context.programs.where(name: arguments[:name].to_s.strip, block: arguments[:block]).first
          return unless existing

          raise Tool::Refusal, "You already have a block named #{existing.name.inspect} (id #{existing.id}). " \
                               'Edit that one, or use a different name.'
        end

        # Absent a date the block starts on the Monday of the current week, the same rule
        # the seeded program uses, so a plan written today is trainable today.
        def self.start_date(arguments)
          return ProgramSeed.monday_of_this_week unless arguments[:start_date]

          Resolver.parse_date(arguments[:start_date])
        end

        def self.lift_count(program)
          program.program_weeks.sum { |week| week.program_days.sum { |day| day.program_lifts.count } }
        end
      end
    end
  end
end

