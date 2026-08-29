# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Removes a session and the sets in it.
      #
      # delete_set existed and this did not, so a workout opened and never logged was
      # permanent -- #261 found two of them, dated 2026-08-16 and 2026-08-18, holding zero
      # sets between them. They are harmless one at a time and they inflate every count on
      # /workouts and in list_workouts, and there was no way to clear one.
      #
      # Sets go first because sets.workout_id is NOT NULL with no cascade, so the parent
      # cannot go while a child points at it. That is the same order and the same
      # transaction POST /workouts/:id/delete has used in the web UI all along; this tool
      # is wrapping a decision that was already made rather than making a new one.
      #
      # A session with lifted sets in it is training that happened, and an assistant
      # tidying up after itself has no business removing it -- so that takes confirm, on
      # the same terms as delete_set. What is returned is the whole session, so a model
      # that has deleted the wrong one has everything it needs to write it back.
      class DeleteWorkout < Tool
        tool_name 'delete_workout'
        description 'Delete a workout and every set in it. Returns what was removed. A ' \
                    'session with completed sets is training history and needs confirm ' \
                    'true, which you should only send if the user asked for it.'
        scope :write
        input_schema(
          type: 'object',
          properties: { workout_id: { type: 'integer' }, confirm: { type: 'boolean' } },
          required: ['workout_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          workout = find(context, arguments[:workout_id])
          removed = Presenter.view_workout_detail(workout)
          refuse_lifted(removed, arguments)
          DB.transaction do
            WorkoutSet.where(workout_id: workout.id).delete
            workout.delete
          end
          ok(sentence(removed), structured: { removed: })
        end

        def self.find(context, id)
          context.workouts.where(id:).first ||
            (raise Tool::Refusal, "No workout with id #{id.inspect} on this account.")
        end

        def self.refuse_lifted(removed, arguments)
          return if removed[:completed].zero? || arguments[:confirm]

          raise Tool::Refusal, "The session on #{removed[:date]} has #{removed[:completed]} " \
                               'completed set(s) in it, so deleting it removes training that ' \
                               'happened. Send confirm true if the user asked to remove it.'
        end

        def self.sentence(removed)
          count = removed[:sets].length
          "Deleted the session on #{removed[:date]}#{" (#{removed[:label]})" if removed[:label]} " \
            "and #{count} set(s) in it, #{removed[:completed]} of them completed."
        end
      end
    end
  end
end

