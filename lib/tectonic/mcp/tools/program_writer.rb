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
          shape = shape_of(attributes, exercise)
          check_load(attributes, shape)
          { sets: attributes[:sets], top_weight: attributes[:top_weight],
            percent_of_max: attributes[:percent_of_max], note: attributes[:note],
            progression: progression_for(attributes, shape),
            is_main: attributes.fetch(:is_main, false),
            is_barbell: barbell?(attributes, exercise, shape) }.merge(shape)
        end

        # The three facts that say how a movement is done, each taken from the movement
        # itself unless this prescription says otherwise. A block may want the dumbbell
        # press done one arm at a time, or the plank held rather than counted, without
        # changing what the movement usually is for every other block.
        def shape_of(attributes, exercise)
          measure = attributes.fetch(:measure, exercise.default_measure).to_s
          { is_weighted: attributes.fetch(:is_weighted, exercise.default_is_weighted),
            measure:,
            is_per_side: attributes.fetch(:is_per_side, exercise.default_is_per_side),
            **quantity(attributes, measure) }
        end

        # A rep count or a duration, never both: the measure names which one, and the
        # column the other would go in stays empty.
        #
        # Read off the resolved measure rather than the argument, because a movement whose
        # own default is time can be prescribed with a duration and nothing else -- asking
        # the arguments would call that a rep-counted lift and then refuse it for having
        # no reps.
        def quantity(attributes, measure)
          return { reps: nil, duration_seconds: attributes[:duration_seconds] } if measure == 'time'

          { reps: attributes[:reps], duration_seconds: nil }
        end

        # Unweighted work is never on a bar, whatever the movement's own flag says, and
        # that one line is what keeps a warmup ramp off it: `Warmup.ramp` returns nothing
        # for work that is not barbell work. Without it a bodyweight lift flagged barbell
        # drew a 45 lb ramp above its own weightless sets.
        def barbell?(attributes, exercise, shape)
          return false unless shape[:is_weighted]

          attributes.fetch(:is_barbell, exercise.barbell?)
        end

        # How a lift is priced already says how it should progress, so an assistant is
        # never asked to state both and cannot state them inconsistently. A percentage is
        # read fresh from the estimated max each week and has therefore already moved by
        # whatever the lifting moved it; pounds are a starting point the rules step from.
        # Unweighted work has no load to decide, so it has no rule at all rather than a
        # rule that means nothing.
        def progression_for(attributes, shape)
          return nil unless shape[:is_weighted]

          attributes[:percent_of_max] ? 'percent' : 'linear'
        end

        def check_load(attributes, shape)
          Bounds.check(Bounds::SETS, attributes[:sets], 'Sets')
          Bounds.check(Bounds::REPS, shape[:reps], 'Reps')
          Bounds.check(Bounds::SECONDS, shape[:duration_seconds], 'Duration', unit: ' seconds')
          Bounds.check(Bounds::WEIGHT, attributes[:top_weight], 'Top weight', unit: ' lb')
          Bounds.check(Bounds::PERCENT, attributes[:percent_of_max], 'Percent of max', unit: '%')
          check_measure(shape)
          check_priced(attributes, shape)
        end

        # A lift is counted one way or the other, and the way it is counted decides which
        # quantity it needs. Asking for time without saying how long is a prescription
        # nobody can follow.
        def check_measure(shape)
          timed = shape[:measure] == 'time'
          unless %w[reps time].include?(shape[:measure])
            raise Tool::Refusal, "Measure #{shape[:measure].inspect} is not one of reps or time."
          end
          return if timed ? shape[:duration_seconds] : shape[:reps]

          raise Tool::Refusal, timed ? 'A timed lift needs duration_seconds.' : 'A lift counted in reps needs reps.'
        end

        # A written zero was the old workaround for bodyweight work, and it is not
        # harmless: zero reads as a real starting load, gains an increment every week the
        # lifter completes it, and three weeks later the app is prescribing a weighted
        # plank.
        def check_priced(attributes, shape)
          return check_unweighted(attributes) unless shape[:is_weighted]
          raise Tool::Refusal, zero_message if attributes[:top_weight]&.zero?
          return if attributes[:top_weight].nil? ^ attributes[:percent_of_max].nil?

          raise Tool::Refusal, 'A lift needs exactly one of top_weight (pounds) or ' \
                               'percent_of_max (a percentage of the estimated max for that movement), ' \
                               'unless is_weighted is false.'
        end

        # Unweighted work carries no load of either kind. Saying it is unweighted and then
        # pricing it is two answers to one question, and the row would fail the database's
        # own check anyway, so it is refused here where the message can name the field.
        def check_unweighted(attributes)
          return if attributes[:top_weight].nil? && attributes[:percent_of_max].nil?

          raise Tool::Refusal, 'An unweighted lift carries no load, so it cannot also have a ' \
                               'top_weight or a percent_of_max. Drop the load, or set is_weighted.'
        end

        def zero_message
          'A lift cannot weigh zero. For a plank, a band, or anything carrying no external ' \
            'load, set is_weighted to false instead.'
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

