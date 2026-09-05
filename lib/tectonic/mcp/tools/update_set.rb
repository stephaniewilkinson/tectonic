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
                    'its reps are per side, or the exercise it is. Send only what ' \
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
                        is_per_side: { type: 'boolean' }, confirm: { type: 'boolean' } },
          required: ['set_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          set = Resolver.find_set(context, arguments[:set_id])
          refuse_swap(set, arguments)
          refuse_overwrite(set, arguments)
          changed = Changes.apply(set, attributes(context, set, arguments))
          ok("#{set.exercise.name} #{Presenter.load_phrase(set)}: #{Changes.describe(changed)}.",
             structured: Presenter.view_set(set.refresh).merge(changed:))
        end

        # A completed set never becomes a different movement. Compared by name rather than
        # through Resolver.exercise on purpose: resolving find-or-creates, so asking it here
        # would leave a brand new movement behind on the way to refusing the call.
        #
        # Naming the movement the set is already on is not a swap and is left alone, so an
        # assistant re-sending the whole row it just read is not refused for a field it did
        # not change.
        def self.refuse_swap(set, arguments)
          return unless set.is_completed && arguments[:exercise]

          named = arguments[:exercise].to_s.strip
          return if named.empty? || named == set.exercise.name

          raise Tool::Refusal,
                "Set #{set.id} is marked as lifted, so it records #{set.exercise.name} that was " \
                "actually performed. A different movement is a different set: delete set #{set.id} " \
                "if it did not happen, and create the #{named} set that did."
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

        # A set moved onto another movement takes that movement's barbell flag with it,
        # the same rule the edit form in the web UI follows: plate math describing the
        # lift that was swapped out is worse than no plate math at all.
        def self.attributes(context, set, arguments)
          fields = written(arguments)
          # The shape the set will be left in, not the one it is in: this is the one tool
          # that can set is_warmup and rpe in a single call, so asking the row as it stands
          # would let a rating through onto a set about to become a warmup.
          Bounds.rating_fits!(fields.fetch(:rpe, set.rpe),
                              warmup: fields.fetch(:is_warmup, set.is_warmup), timed: set.timed?)
          return fields unless arguments[:exercise]

          exercise = Resolver.exercise(context, name: arguments[:exercise])
          return fields if exercise.id == set.exercise_id

          { exercise_id: exercise.id, is_barbell: exercise.barbell? }.merge(fields)
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
          fields = arguments.slice(:weight, :reps, :rpe, :is_warmup, :is_per_side)
          check(fields)
          fields[:weight] = Load.stored(fields[:weight]) if fields.key?(:weight)
          fields
        end

        def self.check(fields)
          Bounds.check(Bounds::WEIGHT, fields[:weight], 'Weight', unit: ' lb')
          Bounds.check(Bounds::REPS, fields[:reps], 'Reps')
          Bounds.check(Bounds::RPE, fields[:rpe], 'RPE')
        end
      end
    end
  end
end

