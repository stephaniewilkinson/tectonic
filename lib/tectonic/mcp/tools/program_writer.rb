# frozen_string_literal: true

require 'date'
require_relative '../tool'
require_relative 'lift_checks'
require_relative 'program_support'
require_relative 'support'
require_relative '../../measured'
require_relative '../../setup'

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
                             position: position || next_position(day_row),
                             **reference(context, attributes),
                             **rounded(load(attributes, exercise), context, exercise))
        end

        # The movement whose max a percentage is taken of, when the prescription names one
        # (#295). Resolved through the same account-scoped resolver every other movement goes
        # through, so a block can never be priced off a stranger's private lift.
        #
        # Absent rather than defaulted: null means "its own max", which is what every lift
        # meant before this, and writing the lift's own id here instead would make a fallback
        # look like a decision somebody made. Whether it is allowed at all is Bounds', beside
        # the other rules about what a field needs next to it to mean anything.
        def reference(context, attributes)
          return {} unless attributes[:percent_of]

          { percent_of_exercise_id: Resolver.exercise(context, name: attributes[:percent_of]).id }
        end

        # The prescription lands on a weight the rack can build (#259). The sets were never
        # the problem -- every weight ProgramGenerator writes goes through Equipment#loading,
        # on generation and on the rewrite after an edit alike, since the editor delegates
        # to the generator's own refresh. What was unrounded was the prescription above
        # them, so a block asking for 152 on a rack whose smallest jump is 5 generated
        # 135/140/145/150, all loadable and all correct, and went on displaying 152.
        # `exercise` is here for the dumbbell count (#439): a size has to go on both ends of
        # every handle in use, so a pair of dumbbells reaches half as far up the shelf as one
        # does, and rounding both against the single's list prescribed weights that cannot be
        # built for any two-handed movement.
        def rounded(attributes, context, exercise)
          return attributes unless attributes[:top_weight] && attributes[:is_weighted]

          attributes.merge(top_weight: Equipment.loadable_for(context.account_id, attributes[:top_weight],
                                                              is_barbell: attributes[:is_barbell],
                                                              dumbbells: exercise.dumbbells))
        end

        # The columns a lift carries, checked here rather than in the schema so an
        # out-of-range number is refused by naming the bound. A lift says what it weighs
        # in one of two ways and has to say it in exactly one: a load that is both an
        # absolute weight and a percentage has no single reading, and one that is neither
        # cannot be generated at all.
        def load(attributes, exercise)
          shape = shape_of(attributes, exercise)
          LiftChecks.check_load(attributes, shape)
          { sets: attributes[:sets], top_weight: attributes[:top_weight],
            percent_of_max: attributes[:percent_of_max], note: attributes[:note],
            progression: progression_for(attributes, shape),
            is_main: attributes.fetch(:is_main, false), target_rpe: attributes[:target_rpe],
            # No shape clause beside it, unlike target_rpe. Rest is the one prescription that
            # means the same thing whatever the movement is -- a plank has a rest between
            # holds and press-ups have one -- so the only question is whether the number is a
            # plausible rest, which Bounds::REST answers on its own. #281.
            rest_seconds: attributes[:rest_seconds],
            # How many rungs the ramp gets, or nil to work it out from how far the top weight
            # is above the bar. Zero is a real answer and means no ramp -- #451 asks for the
            # opt-out outright, for "an accessory late in a session following the same pattern"
            # -- which is why nothing here defaults it or tests it for truthiness. #451.
            warmup_sets: attributes[:warmup_sets],
            # Defaulted to false rather than to anything on the movement, unlike the three
            # facts in shape_of. There is no exercise-level default to read: Bench Press is
            # the same movement whether or not a referee is calling it, which is the whole
            # argument in #311 for a flag on the set instead of a second exercise. A block
            # that wants commanded work says so on the lift that wants it, usually the top
            # single and not the back-offs.
            is_commanded: attributes.fetch(:is_commanded, false),
            is_barbell: barbell?(attributes, exercise, shape) }.merge(shape).merge(Setup.of(attributes))
        end

        # The three facts that say how a movement is done, each taken from the movement
        # itself unless this prescription says otherwise. A block may want the dumbbell
        # press done one arm at a time, or the plank held rather than counted, without
        # changing what the movement usually is for every other block.
        def shape_of(attributes, exercise)
          measure = Measured.cast(attributes.fetch(:measure, exercise.default_measure))
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
          return { reps: nil, duration_seconds: attributes[:duration_seconds] } if measure == Measured::TIME

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

