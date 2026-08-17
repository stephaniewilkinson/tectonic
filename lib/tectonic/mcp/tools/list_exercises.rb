# frozen_string_literal: true

require_relative '../tool'
require_relative 'support'

class Tectonic < Roda
  module MCP
    module Tools
      # Lists the exercises the account can use: its own plus the shared library,
      # never another account's private movements.
      class ListExercises < Tool
        tool_name 'list_exercises'
        description "List the account's exercises and the shared barbell library."
        scope :read
        input_schema(type: 'object', properties: {}, additionalProperties: false)

        def self.perform(context:, **)
          exercises = context.exercises.order(:name).all
          ok("You can use #{exercises.size} exercise(s).",
             structured: { exercises: exercises.map { |e| Presenter.view_exercise(e) } })
        end
      end
    end
  end
end

