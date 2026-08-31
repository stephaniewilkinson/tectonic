# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Puts one weight on every working set of one movement in one session. #312.
      #
      # `update_set` takes a single set_id, so switching a six-set lift from ascending to
      # flat is six calls -- six round trips in which a model can lose its place and leave
      # half a lift at the old weight. That is the argument `create_program` already makes
      # for itself about writing a block one lift at a time, and the session had no
      # equivalent.
      #
      # **The plan side is already covered and this is not it.** `update_program_lift` plus
      # the editor's SessionRefresh rewrites an untrained day from the prescription in one
      # call, which is the better tool when the session has not been started. `refresh`
      # deliberately refuses a session with anything lifted in it -- once a lifter has
      # answered a prescription the rows are a record rather than a plan -- and that is
      # exactly the moment somebody is standing in a gym wanting to change what is left.
      # So this is about the sets, and it is for the case the plan tools decline.
      #
      # Three decisions, all of them about what it must *not* touch:
      #
      # **Completed sets are left alone.** They are a record of what happened, and a bulk
      # edit that rewrote them would delete training to save typing. The count of what was
      # skipped comes back, because a caller that asked for six and moved four needs to know
      # rather than assume.
      #
      # **Warmups are left alone.** A ramp is computed from the top set rather than chosen,
      # so "set every set to 225" would flatten the ramp into six working sets. `is_warmup`
      # is the line and it is not crossed.
      #
      # **planned_weight is left alone**, which is the one that matters most. This writes
      # `weight` only, so the prescription stays as it was and the difference between them
      # goes on being legible -- the same rule complete_set follows, and the thing that lets
      # a session read afterwards as "asked for 225, did 215" rather than as if 215 had been
      # the plan all along.
      class SetWorkingWeight < Tool
        tool_name 'set_working_weight'
        description 'Put one weight on every working set of one movement in a session, ' \
                    'for switching a lift from ascending to flat or dropping what is left ' \
                    'after a bad set. Takes a workout_id and an exercise name. Skips ' \
                    'warmups and anything already completed, and leaves the prescription ' \
                    'alone so what was planned stays readable beside what was done. ' \
                    'Returns how many sets moved and how many were left.'
        scope :write
        input_schema(
          type: 'object',
          properties: { workout_id: { type: 'integer' }, exercise: { type: 'string' },
                        weight: { type: 'number' } },
          required: %w[workout_id exercise weight], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          Bounds.check(Bounds::WEIGHT, arguments[:weight], 'Weight', unit: ' lb')
          workout = find(context, arguments[:workout_id])
          exercise = movement(context, arguments[:exercise])
          moved = apply(workout, exercise, arguments[:weight])
          ok(sentence(exercise, moved, arguments[:weight]), structured: moved.merge(workout_id: workout.id))
        end

        # The sets this may write to: not a warmup, not already done. Counted before and
        # after rather than reported as "all of them", because the two numbers are the whole
        # answer -- a lifter three sets into a lift wants to know the three they finished
        # were not touched.
        def self.apply(workout, exercise, weight)
          candidates = WorkoutSet.where(workout_id: workout.id, exercise_id: exercise.id, is_warmup: false)
          movable = candidates.exclude(is_completed: true)
          { moved: movable.update(weight:), left: candidates.where(is_completed: true).count }
        end

        # By id, scoped to the account, which is what makes another account's session
        # unreachable rather than merely unlikely.
        def self.find(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end

        # Resolved among the movements this account can see, without creating one. A bulk
        # edit naming a movement that is not in the session is a mistake worth refusing --
        # creating the movement to write nothing to it would leave a row behind and report
        # success.
        def self.movement(context, name)
          context.exercises.where(name: name.to_s.strip).order(:id).first ||
            (raise Tool::Refusal, "No exercise named #{name.to_s.strip.inspect} for this account.")
        end

        # Says what moved and what did not, because "0 sets" and "0 sets, 4 already done" are
        # different answers and only one of them means the caller got the movement wrong.
        def self.sentence(exercise, moved, weight)
          done = moved[:left].positive? ? ", #{moved[:left]} already completed and left alone" : ''
          "#{exercise.name}: #{moved[:moved]} working set(s) set to #{Presenter.weight(weight)}#{done}."
        end
      end
    end
  end
end

