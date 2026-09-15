# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
# Exercise#barbell?, which is what a logged set inherits its plate math from.
require_relative '../../exercise_library'

class Tectonic < Roda
  module MCP
    module Tools
      # Logs one set: resolves-or-creates the exercise by name and the workout by
      # date (both through the shared Resolver, so the set can only ever land on the
      # account's own workout), after range-checking weight and reps.
      class CreateSet < Tool
        tool_name 'create_set'
        title 'Log a set'
        description 'Log a set of an exercise (by name) into a workout (by date, ' \
                    "'today' by default). Weights are integer pounds, rpe is how hard " \
                    'that set was on the 1-10 scale. Leave weight out for work carrying ' \
                    'no external load -- a plank, a band pull-apart, a bodyweight hip ' \
                    'thrust -- which is recorded as a rep count with no weight at all. ' \
                    'is_per_side says the rep count is per side; leave it out and the ' \
                    "movement's own default decides, which is right for most callers. " \
                    'is_commanded says the set was done under meet commands -- start, ' \
                    'press, rack -- rather than at the lifter\'s own tempo. It is a ' \
                    'competition condition and not a tempo, so it is not the same thing as ' \
                    'a paused rep; it defaults to false and should be sent only when the ' \
                    'lifter says the set was commanded. Work counted in seconds rather than ' \
                    "reps -- a plank, a walk, a bike interval -- sends measure 'time' and " \
                    'duration_seconds instead of reps, and carries no rpe: RPE is reps in ' \
                    'reserve and a held position has none. bench_angle_degrees, rack_hole ' \
                    'and safety_hole record how the room was set up for this set.'
        scope :write
        input_schema(
          type: 'object',
          properties: {
            exercise: { type: 'string' }, date: { type: 'string' },
            weight: { type: 'number' }, reps: { type: 'integer' }, rpe: { type: 'integer' },
            is_warmup: { type: 'boolean' }, is_completed: { type: 'boolean' },
            is_per_side: { type: 'boolean' }, is_commanded: { type: 'boolean' },
            measure: { type: 'string', enum: %w[reps time] },
            duration_seconds: { type: 'integer' },
            bench_angle_degrees: { type: 'integer' }, rack_hole: { type: 'integer' },
            safety_hole: { type: 'integer' }
          },
          # reps is no longer required, because a timed set has none and the column refuses
          # one -- `sets_measures_one_way` is reps XOR duration_seconds, matched to measure.
          # What replaces the requirement is `measured!` below, which names whichever of the
          # two is missing instead of letting the schema say "missing required arguments:
          # reps" to somebody logging a bike ride.
          required: %w[exercise], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          check_range(arguments)
          exercise = Resolver.exercise(context, name: arguments[:exercise])
          workout = Resolver.workout(context, date: arguments[:date])
          set = WorkoutSet.create(attributes(arguments, exercise, workout, context))
          ok("Logged #{Presenter.load_phrase(set)} of #{exercise.name} (id #{set.id}).",
             structured: Presenter.view_set(set))
        end

        # The ranges are Bounds', shared with every other tool that writes a weight or a
        # rep count, so the same number is refused the same way whether it is being
        # logged here, revised through update_set, or prescribed in a program.
        def self.check_range(arguments)
          Bounds.check(Bounds::WEIGHT, arguments[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, arguments[:reps], 'Reps')
          Bounds.check(Bounds::RPE, arguments[:rpe], 'RPE')
          Bounds.check(Bounds::SECONDS, arguments[:duration_seconds], 'Duration', unit: ' seconds')
          Bounds.setup_fits!(arguments)
          measured!(arguments)
          Bounds.rating_fits!(arguments[:rpe], warmup: arguments.fetch(:is_warmup, false),
                                               timed: timed?(arguments))
          Bounds.commands_fit!(arguments[:is_commanded], measure: measure_of(arguments))
        end

        # How this set is counted, inferred where the caller did not say. #471.
        #
        # Inferring rather than defaulting to reps is what makes the ordinary call still
        # work while the new one needs no ceremony: a caller sending duration_seconds means
        # a timed set whether or not they knew the field existed, and one sending reps means
        # a counted one. Only a caller sending both, or neither, has to be asked.
        def self.measure_of(arguments)
          return Measured.cast(arguments[:measure]) if arguments[:measure]
          return Measured::TIME if arguments[:duration_seconds]

          Measured::REPS
        end

        def self.timed?(arguments) = measure_of(arguments) == Measured::TIME

        # The column refuses reps and a duration together, and refuses neither. Said here so
        # it reads as a sentence a model can act on rather than as a check violation, which
        # is what #213 is about and what `sets_measures_one_way` would otherwise produce.
        def self.measured!(arguments)
          both!(arguments)
          timed?(arguments) ? timed!(arguments) : counted!(arguments)
        end

        def self.timed!(arguments)
          raise Tool::Refusal, timed_wants_seconds if arguments[:duration_seconds].nil?
          raise Tool::Refusal, timed_refuses_reps unless arguments[:reps].nil?
        end

        def self.counted!(arguments)
          raise Tool::Refusal, counted_wants_reps if arguments[:reps].nil?
          raise Tool::Refusal, counted_refuses_seconds if arguments[:duration_seconds]
        end

        # Reps and a duration together, with nothing saying which the set is. Inferring
        # either one would be the tool deciding what somebody trained, and the two readings
        # are not close: sixty reps and sixty seconds are different sets. So it asks.
        #
        # Separate from the branches below because those answer "you sent the wrong one for
        # the measure you named" -- here no measure was named, and that is the whole problem.
        def self.both!(arguments)
          return if arguments[:measure]
          return unless arguments[:reps] && arguments[:duration_seconds]

          raise Tool::Refusal,
                'This set cannot be both counted and timed: it carries reps and duration_seconds ' \
                "with no measure to say which it is. Send measure 'reps' or measure 'time', or " \
                'send only the one that applies.'
        end

        def self.timed_wants_seconds
          'A set measured in time needs duration_seconds. Send it instead of reps -- a 1h 7m ride is 4020.'
        end

        def self.timed_refuses_reps
          'A set measured in time is counted in seconds, not reps. Send duration_seconds alone.'
        end

        def self.counted_wants_reps
          "This set needs reps. If it was held or ridden rather than counted, send measure 'time' " \
            'and duration_seconds instead.'
        end

        def self.counted_refuses_seconds
          "A set counted in reps cannot also carry a duration. Send measure 'time' to record it as " \
            'time, or leave duration_seconds out.'
        end

        # is_barbell comes off the movement rather than the arguments: whether a lift is
        # loaded on a bar is a fact about the lift, not something a model should be asked
        # to assert, and a schema that asked would get it wrong or omitted and the set
        # would lose its plate math either way.
        #
        # is_per_side is the same fact of the same kind, and defaults the same way (#320).
        # It was missing entirely, so every set an assistant logged was bilateral whatever
        # the movement was -- which is why a Single-Leg Hip Thrust rendered without the "per
        # side" the session screen was perfectly willing to draw. The screen was right and
        # the row was wrong. `Volume::WORKED_REPS` doubles on this flag, so the same gap was
        # counting half the reps and half the tonnage of every unilateral movement.
        #
        # Defaulting to the exercise's own `default_is_per_side` rather than to false is
        # what makes most callers right without knowing the field exists -- the rule
        # ProgramWriter.shape_of already follows on the prescription side.
        # How this set is counted. Stored as the string the column holds, through Measured,
        # so this and the program side cannot disagree about what "time" is spelled as.
        def self.counted(arguments)
          { measure: Measured.stored(measure_of(arguments)),
            duration_seconds: arguments[:duration_seconds] }
        end

        # How the room was set up, which the prescription side has recorded since #412 and
        # the logging side had no way to say at all -- so a set logged outside a generated
        # session lost the bench angle and the pin heights the lift it came from carries.
        def self.setup(arguments)
          { bench_angle_degrees: arguments[:bench_angle_degrees],
            rack_hole: arguments[:rack_hole], safety_hole: arguments[:safety_hole] }
        end

        def self.attributes(arguments, exercise, workout, context)
          { exercise_id: exercise.id, workout_id: workout.id,
            weight: Load.stored(arguments[:weight]), reps: arguments[:reps], rpe: arguments[:rpe],
            **counted(arguments), **setup(arguments),
            is_warmup: arguments.fetch(:is_warmup, false), is_barbell: exercise.barbell?,
            is_per_side: arguments.fetch(:is_per_side, exercise.default_is_per_side),
            # False rather than the movement's own anything, because there is nothing on a
            # movement to read: Bench Press is the same movement whether or not a referee is
            # calling it, which is #311's argument for a flag here instead of a second
            # exercise. Every set this tool writes is counted in reps, so
            # sets_commanded_reps_are_counted cannot be reached from here.
            is_commanded: arguments.fetch(:is_commanded, false),
            # A set logged as already done is stamped with when it was logged, which is the
            # best this path can say (#281). It is not when it was lifted -- a session typed
            # up in the evening stamps the evening -- so the turnarounds such a session
            # produces describe the typing rather than the training. That is honest about
            # what the column holds and is why Timing never claims a turnaround is a rest.
            **WorkoutSet.completion(arguments.fetch(:is_completed, false)),
            created_by_oauth_application_id: context.application_id, created_at: Time.now }
        end
      end
    end
  end
end

