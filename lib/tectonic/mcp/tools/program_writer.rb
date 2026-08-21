# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'program_support'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Writing the parts of a block. Every program write tool goes through here, so a
      # lift added to an existing day and a lift written as part of a whole new block are
      # built by the same code and come out identical -- including the checks, which is
      # the part that would otherwise drift.
      module ProgramWriter
        module_function

        # A week and everything under it. Numbering defaults to the position in the list
        # the model sent, so an assistant writing four weeks does not have to number them
        # and cannot number them inconsistently.
        def week(context, program, attributes, number)
          row = ProgramWeek.create(program_id: program.id, number: attributes[:number] || number,
                                   is_deload: attributes.fetch(:is_deload, false), notes: attributes[:notes])
          Array(attributes[:days]).each { |written| day(context, row, written) }
          row
        end

        def day(context, week_row, attributes)
          row = ProgramDay.create(program_week_id: week_row.id, weekday: weekday(attributes[:weekday]),
                                  focus: attributes[:focus])
          Array(attributes[:lifts]).each_with_index { |written, index| lift(context, row, written, index) }
          row
        end

        # A lift at a position, which is the order it will be generated and the order it
        # will appear in the session. Position defaults to the end of the day, so adding
        # work to a day never silently reorders what is already there.
        def lift(context, day_row, attributes, position = nil)
          exercise = Resolver.exercise(context, name: attributes[:exercise])
          ProgramLift.create(program_day_id: day_row.id, exercise_id: exercise.id,
                             position: position || next_position(day_row), **load(attributes, exercise))
        end

        # The columns a lift carries, checked here rather than in the schema so an
        # out-of-range number is refused by naming the bound. A lift says what it weighs
        # in one of two ways and has to say it in exactly one: a load that is both an
        # absolute weight and a percentage has no single reading, and one that is neither
        # cannot be generated at all.
        def load(attributes, exercise)
          check_load(attributes)
          { sets: attributes[:sets], reps: attributes[:reps], top_weight: attributes[:top_weight],
            percent_of_max: attributes[:percent_of_max], note: attributes[:note],
            is_main: attributes.fetch(:is_main, false),
            is_barbell: attributes.fetch(:is_barbell, exercise.barbell?) }
        end

        def check_load(attributes)
          Bounds.check(Bounds::SETS, attributes[:sets], 'Sets')
          Bounds.check(Bounds::REPS, attributes[:reps], 'Reps')
          Bounds.check(Bounds::WEIGHT, attributes[:top_weight], 'Top weight', unit: ' lb')
          Bounds.check(Bounds::PERCENT, attributes[:percent_of_max], 'Percent of max', unit: '%')
          return if attributes[:top_weight].nil? ^ attributes[:percent_of_max].nil?

          raise Tool::Refusal, 'A lift needs exactly one of top_weight (pounds) or ' \
                               'percent_of_max (a percentage of the estimated max for that movement).'
        end

        # Sunday is 0 through Saturday is 6, which is the numbering the rest of the app
        # uses; anything else is refused rather than silently taken modulo seven.
        def weekday(value)
          return value if value.is_a?(Integer) && (0..6).cover?(value)

          raise Tool::Refusal, "Weekday #{value.inspect} is out of range; use 0 (Sunday) to 6 (Saturday)."
        end

        def next_position(day_row)
          (day_row.program_lifts.map(&:position).max || -1) + 1
        end

        # Moves a lift within its day and renumbers the rest from zero. Writing the new
        # position onto the one row would leave two lifts claiming the same place and the
        # order between them decided by whatever the database felt like returning, which
        # is not an order a lifter can follow down a session screen.
        def reposition(lift, position)
          siblings = lift.program_day.program_lifts.sort_by(&:position)
          siblings.delete_if { |row| row.id == lift.id }
          siblings.insert(position.clamp(0, siblings.length), lift)
          siblings.each_with_index { |row, index| row.update(position: index) if row.position != index }
          lift.refresh
        end
      end
    end
  end
end

