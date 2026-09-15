# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Corrects a set that is already there: its weight, its reps, its rating, whether it
      # is a warmup, or which movement it is. Distinct from complete_set, which is about
      # having lifted something; this is about the row being wrong.
      #
      # A set already marked as lifted is training history, and this tool used to rewrite it
      # without a word. #364: three sets of DB Overhead Tricep Extension performed at 14x20,
      # 20x10 and 20x15 were turned into Band Tricep Pushdown by an assistant tidying a
      # program, and the loads and reps went with them -- not moved, not archived,
      # overwritten. Nothing objected. The only reason it was noticed is that the response
      # echoed the old values back and a person read them.
      #
      # That was a strange asymmetry rather than a considered position: `delete_set`,
      # `delete_workout` and `delete_program` all guard exactly this case, and changing a
      # completed set's exercise destroys the same information a deletion would. So the same
      # guard applies here, in the two shapes the damage actually takes:
      #
      #   * **A different movement is refused outright**, with no confirm to override it. A
      #     swap says a different exercise was performed, which is a new set rather than an
      #     edited one -- there is no reading of it under which the old load and reps are
      #     still true, so an escape hatch would only be a way to lose them politely.
      #   * **A different weight or rep count needs `confirm`.** Correcting a typo is
      #     legitimate and stays possible; it just stops being silent.
      #
      # A rating is deliberately not guarded. Rating a set after the fact is the ordinary
      # way round -- the number is what the lifter says it was -- and it overwrites nothing
      # that was measured. Nor is `is_warmup`: it reclassifies the set without touching what
      # was done in it.
      class UpdateSet < Tool
        # The columns that record what was actually lifted, so writing over one of them on a
        # completed set is rewriting history rather than fixing a row.
        LIFTED = %i[weight reps].freeze

        tool_name 'update_set'

        title 'Correct a set'
        description 'Correct a set: weight, reps, rpe, whether it is a warmup, whether ' \
                    'its reps are per side, whether it was done under meet commands ' \
                    '(is_commanded -- start, press, rack, rather than the lifter\'s own ' \
                    'tempo), or the exercise it is. Send only what ' \
                    'changes. Returns what actually moved. ' \
                    'Changing the weight or reps of a completed set needs confirm true, ' \
                    'which you should only send if the user asked for the correction; ' \
                    'changing its exercise is refused, since that is a different set.'
        scope :write
        input_schema(
          type: 'object',
          properties: { set_id: { type: 'integer' }, weight: { type: 'number' },
                        reps: { type: 'integer' }, rpe: { type: 'integer' },
                        is_warmup: { type: 'boolean' }, exercise: { type: 'string' },
                        is_per_side: { type: 'boolean' }, is_commanded: { type: 'boolean' },
                        duration_seconds: { type: 'integer' }, relabel: { type: 'boolean' },
                        bench_angle_degrees: { type: 'integer' }, rack_hole: { type: 'integer' },
                        safety_hole: { type: 'integer' },
                        confirm: { type: 'boolean' } },
          required: ['set_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          set = Resolver.find_set(context, arguments[:set_id])
          refuse_swap(set, arguments)
          counted_as!(set, arguments)
          refuse_overwrite(set, arguments)
          changed = Changes.apply(set, attributes(context, set, arguments))
          ok("#{set.exercise.name} #{Presenter.load_phrase(set)}: #{Changes.describe(changed)}.",
             structured: Presenter.view_set(set.refresh).merge(changed:))
        end

        # A completed set never becomes a different movement *by accident*. #364, and #463
        # is the exception it turned out to need.
        #
        # The rule is right about a swap. A swap says a different movement was performed, and
        # the load and reps on the row are then describing something that did not happen --
        # there is no reading under which they survive, so the honest answer is a new set.
        #
        # It is wrong about a **mis-record**, which is a different claim wearing the same
        # shape. On 2026-09-01 three sets went into the log as Dumbbell Overhead Press at
        # 45/65/65 because changing the movement mid-session cost more than living with it.
        # The barbell is what was lifted. The load and reps are *true*; only the label is
        # wrong, applied by somebody who could not change it at the moment they needed to.
        # Refusing that is not protecting history, it is preserving a known error in it -- and
        # the route out, delete and re-create, costs twice the calls the friction did.
        #
        # So the two are told apart by the caller saying which they mean. `relabel` and not
        # the existing `confirm`, deliberately: confirm answers "yes, overwrite what this
        # completed set measured", and these are different questions about the same row. One
        # flag answering both would let a caller confirming a weight correction silently
        # authorise a change of movement as well.
        #
        # Compared by name rather than through Resolver.exercise on purpose: resolving
        # find-or-creates, so asking it here would leave a brand new movement behind on the
        # way to refusing the call.
        #
        # Naming the movement the set is already on is not a swap and is left alone, so an
        # assistant re-sending the whole row it just read is not refused for a field it did
        # not change.
        def self.refuse_swap(set, arguments)
          return unless set.is_completed && arguments[:exercise]
          return if arguments[:relabel]

          named = arguments[:exercise].to_s.strip
          return if named.empty? || named == set.exercise.name

          raise Tool::Refusal,
                "Set #{set.id} is marked as lifted, so it records #{set.exercise.name} that was " \
                "actually performed. If a different movement was performed, delete set #{set.id} " \
                "and create the #{named} set that did happen. If this set is right and only its " \
                'name is wrong -- it was logged under the wrong movement -- send relabel: true.'
        end

        # The weight and reps of a completed set, behind the same confirm delete_set uses.
        # Only fields that would actually move count, so re-sending a value the row already
        # carries is not an overwrite and does not need confirming.
        def self.refuse_overwrite(set, arguments)
          return if arguments[:confirm] || !set.is_completed

          moved = LIFTED.select { |field| rewrites?(set, arguments, field) }
          return if moved.empty?

          raise Tool::Refusal,
                "Set #{set.id} is marked as lifted, so changing its #{moved.join(' and ')} rewrites " \
                'training that happened. Send confirm true if the user asked to correct it.'
        end

        # Whether an argument would move a column off what it holds. A weight goes through
        # Load.stored first so that a zero, which this tool reads as bodyweight (#321), is
        # compared as the nil it will be written as rather than as the number that was sent.
        def self.rewrites?(set, arguments, field)
          return false unless arguments.key?(field)

          sent = field == :weight ? Load.stored(arguments[:weight]) : arguments[field]
          set[field] != sent
        end

        # A set moved onto another movement takes that movement's barbell flag with it, and
        # leaves the old movement's prescription behind -- both through WorkoutSet.moved_to,
        # which is the one place that rule lives now (#406). Plate math describing the lift
        # that was swapped out is worse than none, and so is a planned weight.
        def self.attributes(context, set, arguments)
          fields = written(arguments)
          check_placement(set, fields)
          return fields unless arguments[:exercise]

          exercise = Resolver.exercise(context, name: arguments[:exercise])
          return fields if exercise.id == set.exercise_id

          WorkoutSet.moved_to(exercise).merge(fields)
        end

        # The two fields that need somewhere to sit rather than only a range, checked
        # together because they are the same kind of rule and refused by name because the
        # alternative is a check violation reaching a client as a database error.
        def self.check_placement(set, fields)
          # The shape the set will be left in, not the one it is in: this is the one tool
          # that can set is_warmup and rpe in a single call, so asking the row as it stands
          # would let a rating through onto a set about to become a warmup.
          Bounds.rating_fits!(fields.fetch(:rpe, set.rpe),
                              warmup: fields.fetch(:is_warmup, set.is_warmup), timed: set.timed?)
          # Asked of the row's own measure, unlike the rating above, because this tool cannot
          # change a set's measure -- there is no `measure` in its schema, and a plank stays a
          # plank through every correction it accepts. #311.
          Bounds.commands_fit!(fields[:is_commanded], measure: set.measure)
        end

        # The columns as they will be stored: range-checked, and a weight of zero read as
        # bodyweight on the same terms as in create_set (#321), so a set logged with a load
        # and then corrected to none can be said the obvious way.
        #
        # `key?` rather than a truthiness check, so this fires only on a weight that was
        # actually sent -- an unmentioned one is left exactly as it was, which is what makes
        # "send only what changes" true of this field as well as the rest.
        # is_per_side is here rather than in LIFTED above, and so is not behind confirm.
        # Correcting it does not overwrite anything that was measured -- the rep count on
        # the row is unchanged -- it says how that count should be read, and #320 is
        # precisely the case of a set logged bilaterally that was not. A guard would put
        # confirm in front of the fix for the bug that made the flag necessary.
        def self.written(arguments)
          # is_commanded joins is_per_side outside LIFTED for the same reason and not behind
          # confirm: it says how the set was performed rather than overwriting what was
          # measured, and remembering after the session that the top single was commanded is
          # the ordinary way round. #311.
          fields = arguments.slice(:weight, :reps, :rpe, :is_warmup, :is_per_side, :is_commanded,
                                   :duration_seconds, :bench_angle_degrees, :rack_hole, :safety_hole)
          check(fields)
          fields[:weight] = Load.stored(fields[:weight]) if fields.key?(:weight)
          fields
        end

        def self.check(fields)
          Bounds.check(Bounds::WEIGHT, fields[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, fields[:reps], 'Reps')
          Bounds.check(Bounds::RPE, fields[:rpe], 'RPE')
          Bounds.check(Bounds::SECONDS, fields[:duration_seconds], 'Duration', unit: ' seconds')
          Bounds.setup_fits!(fields)
        end

        # A correction has to be counted the way the set already is. #471.
        #
        # `sets_measures_one_way` holds reps XOR duration_seconds, matched to measure, and
        # this tool takes no measure on purpose -- a plank stays a plank. So sending reps to
        # a timed set, or a duration to a counted one, asks the column for a row it refuses,
        # and until now that surfaced as "The tool failed unexpectedly and made no change":
        # a check violation reaching a model as a shrug. #213's shape exactly.
        #
        # Said as a refusal naming the set's own measure, because the caller's mistake is
        # almost always that they do not know which kind of set they are holding.
        def self.counted_as!(set, fields)
          timed = set.measure == Measured::TIME
          raise Tool::Refusal, wrong_count(set, 'reps', 'duration_seconds') if timed && fields.key?(:reps)
          return unless !timed && fields.key?(:duration_seconds)

          raise Tool::Refusal, wrong_count(set, 'a duration', 'reps')
        end

        def self.wrong_count(set, sent, wanted)
          "Set #{set.id} is counted in #{set.measure == Measured::TIME ? 'seconds' : 'reps'}, " \
            "so it cannot take #{sent}. Send #{wanted} instead, or delete it and log the set " \
            'the way it was actually done.'
        end
      end
    end
  end
end

