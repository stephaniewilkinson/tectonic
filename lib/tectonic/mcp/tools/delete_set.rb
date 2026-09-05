# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Removes a set an assistant should not have written.
      #
      # A real delete, not a flag. Nothing in the schema points at a set, so removing one
      # orphans nothing; a soft delete would mean a column and then every reader in the
      # app -- the session screen, the set counts, the exercise history, the estimated max
      # -- remembering to filter on it, and the first one to forget quietly counts deleted
      # work as training. The row's contents come back in the result, so a model that has
      # just deleted the wrong set can put it back with create_set.
      #
      # Work that was actually lifted is not deleted on a model's say-so. A completed set
      # is training history, and an assistant tidying up after itself has no business
      # removing it, so that takes an explicit confirm -- which a user asking for it will
      # produce and a confused model will not.
      class DeleteSet < Tool
        tool_name 'delete_set'
        title 'Delete a set'
        description 'Delete a set. Returns what was removed so it can be logged again if ' \
                    'that was a mistake. A completed set is training history and needs ' \
                    'confirm true, which you should only send if the user asked for it.'
        scope :write
        destroys
        input_schema(
          type: 'object',
          properties: { set_id: { type: 'integer' }, confirm: { type: 'boolean' } },
          required: ['set_id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          set = Resolver.find_set(context, arguments[:set_id])
          refuse_completed(set, arguments)
          removed = Presenter.view_set(set)
          date = set.workout.date.strftime('%Y-%m-%d')
          set.delete
          ok("Deleted #{removed[:exercise]} #{removed[:weight]}x#{removed[:reps]} from #{date}.",
             structured: { removed: })
        end

        def self.refuse_completed(set, arguments)
          return unless set.is_completed && !arguments[:confirm]

          raise Tool::Refusal, "Set #{set.id} is marked as lifted, so deleting it removes " \
                               'training that happened. Send confirm true if the user asked to remove it.'
        end
      end
    end
  end
end

