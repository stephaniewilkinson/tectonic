# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Lists the account's workouts, most recent first, never another account's.
      class ListWorkouts < Tool
        tool_name 'list_workouts'
        description "List the account's workouts, most recent first, with set counts."
        scope :read
        input_schema(type: 'object', properties: {}, additionalProperties: false)

        def self.perform(context:, **)
          workouts = context.workouts.order(Sequel.desc(:date)).all
          ok("You have #{workouts.size} workout(s).",
             structured: { workouts: workouts.map { |w| Presenter.workout_view(w) } })
        end
      end
    end
  end
end
