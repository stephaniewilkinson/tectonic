# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'
# Exercise#barbell?, which a set takes with it when it moves onto another movement.
require_relative '../../exercise_library'

class Tectonic < Roda
  module MCP
    module Tools
      # Swaps every set of one movement in a session for another, in one call. #365.
      #
      # `update_set` could already do this a set at a time, and that is the whole problem:
      # swapping dumbbell overhead press for the barbell on a written session took three
      # calls for three sets, and six on a movement with a ramp. The decision is made
      # standing at the rack against a hard stop, which is the worst moment in the app to
      # charge six round trips for one thought -- so on 2026-09-01 three sets went into the
      # log as Dumbbell Overhead Press at 45/65/65 because logging the wrong movement was
      # quicker than correcting it.
      #
      # **Sets already marked as lifted do not move**, which is #364 and is not negotiable
      # here. A completed set records a movement that was performed; a swap says a different
      # one was, and there is no reading under which the recorded load and reps are still
      # true. So this moves the sets still standing as prescription and reports the lifted
      # ones as left alone, with the same delete-and-create route #364 points at. That is
      # also the honest answer to the case in the issue: the swap is a decision about what
      # is *about to* be lifted, and the sets it is made in front of are exactly the ones
      # that have not been done yet.
      class UpdateWorkoutExercise < Tool
        tool_name 'update_workout_exercise'
        title 'Swap a movement in a session'
        description 'Swap every set of one movement in a session for another, in one ' \
                    'call, instead of one call per set. Sets already marked as lifted ' \
                    'are left alone, since those record what was actually performed. Send ' \
                    'relabel true only when those sets are right and their name is wrong -- ' \
                    'the work was done, and logged under the wrong movement -- which moves ' \
                    'them too.'
        scope :write
        input_schema(
          type: 'object',
          properties: { workout_id: { type: 'integer' }, from_exercise: { type: 'string' },
                        to_exercise: { type: 'string' }, relabel: { type: 'boolean' } },
          required: %w[workout_id from_exercise to_exercise], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find_workout(context, arguments[:workout_id])
          plan = planned(context, workout, arguments)
          return unchanged(plan.from, plan.into) if plan.into.id == plan.from.id

          move(context, workout, plan)
        end

        def self.planned(context, workout, arguments)
          from = named_in(workout, arguments[:from_exercise])
          sets = workout.sets_dataset.where(exercise_id: from.id).order(:id).all
          relabel = arguments[:relabel] || false
          refuse_all_lifted(from, sets) unless relabel
          Move.of(from, Resolver.exercise(context, name: arguments[:to_exercise]), sets, relabel)
        end

        # What one call is about to do, gathered so the methods below take one argument
        # rather than six. `moving` and `left` are the whole of the #463 difference: a swap
        # leaves the lifted sets where they are, and a relabel takes them along.
        Move = Struct.new(:from, :into, :moving, :left, :relabel) do
          def self.of(from, into, sets, relabel)
            lifted, pending = sets.partition(&:is_completed)
            new(from, into, relabel ? sets : pending, relabel ? [] : lifted, relabel)
          end
        end

        # The session by id, on this account only. Refused rather than nil: an id belonging
        # to somebody else must not read as an empty session an assistant then reports it
        # swapped nothing in.
        def self.find_workout(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end

        # The movement being swapped out, matched among the ones this account can see. A
        # name nothing answers to is refused rather than created -- Resolver.exercise
        # find-or-creates, which is right when a set is being written onto a movement and
        # exactly wrong here, where a typo would otherwise invent a movement, find none of
        # it in the session, and report a successful swap of nothing.
        def self.named_in(workout, name)
          clean = name.to_s.strip
          raise Tool::Refusal, 'Name the movement to swap out.' if clean.empty?

          found = Exercise.where(id: workout.sets_dataset.select_map(:exercise_id).uniq,
                                 name: clean).order(:id).first
          return found if found

          raise Tool::Refusal, "No sets of #{clean.inspect} in the session on " \
                               "#{workout.date.strftime('%Y-%m-%d')}."
        end

        # Nothing to do, said as a refusal rather than as a success over zero rows. A
        # session whose every set of a movement is lifted is #364's case arriving through
        # this door, and the answer is the same one.
        def self.refuse_all_lifted(from, sets)
          return unless sets.all?(&:is_completed)

          raise Tool::Refusal,
                "Every set of #{from.name} in this session is marked as lifted, so they record what " \
                'was actually performed. If a different movement was performed, delete those and ' \
                'create the ones that happened. If they are right and only the name is wrong, send ' \
                'relabel: true.'
        end

        # The move itself, through WorkoutSet.moved_to so that this and update_set and the
        # session screen's swap control cannot disagree about what moving a set means (#406):
        # the new movement's barbell flag travels with it, and the old movement's
        # prescription does not. Plate math describing the movement that was swapped out is
        # worse than none at all, and so is a planned weight.
        # `relabel` is #463: the sets are right and their name is wrong, so the lifted ones
        # move with the rest instead of being left behind. It is a different claim from a
        # swap, not a louder version of one -- a swap says other work was done, and a relabel
        # says this work was misfiled -- which is why it is its own flag rather than a
        # confirm on the refusal above.
        def self.move(context, workout, plan)
          WorkoutSet.where(id: plan.moving.map(&:id)).update(**WorkoutSet.moved_to(plan.into))
          ok(moved_phrase(workout, plan),
             structured: { moved: plan.moving.length, left_lifted: plan.left.length,
                           relabelled: plan.relabel,
                           workout: Presenter.view_workout_detail(workout.refresh, on: context.today) })
        end

        # Naming the movement a session is already on is not a swap. Said plainly rather
        # than counted as a move, so an assistant re-sending a call does not read its own
        # no-op as having changed something.
        def self.unchanged(from, into)
          ok("Every set is already #{into.name}; nothing to swap.",
             structured: { moved: 0, left_lifted: 0, unchanged: from.name })
        end

        def self.moved_phrase(workout, plan)
          date = workout.date.strftime('%Y-%m-%d')
          verb = plan.relabel ? 'Relabelled' : 'Swapped'
          moved = "#{verb} #{plan.moving.length} set(s) of #{plan.from.name} as #{plan.into.name} on #{date}."
          return moved if plan.left.empty?

          "#{moved} Left #{plan.left.length} set(s) already marked as lifted on #{plan.from.name}: " \
            'those record what was performed, so delete and re-create them if they are wrong, or ' \
            'send relabel: true if they are right and only the name is wrong.'
        end
      end
    end
  end
end

