# frozen_string_literal: true

require 'mcp'
require_relative 'config'
require_relative 'tools/whoami'
require_relative 'tools/create_exercise'
require_relative 'tools/update_exercise'
require_relative 'tools/create_workout'
require_relative 'tools/update_workout'
require_relative 'tools/create_set'
require_relative 'tools/complete_set'
require_relative 'tools/update_set'
require_relative 'tools/set_working_weight'
require_relative 'tools/delete_set'
require_relative 'tools/delete_workout'
require_relative 'tools/get_workout'
require_relative 'tools/exercise_history'
require_relative 'tools/set_training_max'
require_relative 'tools/list_exercises'
require_relative 'tools/list_workouts'
require_relative 'tools/list_programs'
require_relative 'tools/get_program'
require_relative 'tools/create_program'
require_relative 'tools/update_program'
require_relative 'tools/delete_program'
require_relative 'tools/add_program_week'
require_relative 'tools/add_program_day'
require_relative 'tools/update_program_day'
require_relative 'tools/add_program_lift'
require_relative 'tools/update_program_lift'
require_relative 'tools/delete_program_lift'
require_relative 'tools/generate_program_week'
require_relative 'tools/search'
require_relative 'tools/fetch'

class Tectonic < Roda
  module MCP
    # Builds the MCP server for one request, wired to that request's account context.
    # The mcp gem fixes server_context at construction and stateless mode holds no
    # state between requests, so a fresh server per request is how per-account scoping
    # is reached without any shared mutable state.
    module ServerFactory
      # Every tool the server exposes, grouped the way an assistant works: log what was
      # lifted, read what has been, and write and revise the plan behind it. Registering a
      # new tool is adding its class here (and requiring it above); auth, scoping,
      # validation, and auditing come from the base class.
      TOOLS = [
        Tools::Whoami,
        Tools::CreateExercise, Tools::UpdateExercise, Tools::CreateWorkout, Tools::UpdateWorkout,
        Tools::CreateSet, Tools::CompleteSet, Tools::UpdateSet, Tools::SetWorkingWeight,
        Tools::DeleteSet, Tools::DeleteWorkout,
        Tools::ListExercises, Tools::ListWorkouts, Tools::GetWorkout, Tools::ExerciseHistory,
        Tools::SetTrainingMax,
        Tools::ListPrograms, Tools::GetProgram, Tools::CreateProgram,
        Tools::UpdateProgram, Tools::DeleteProgram,
        Tools::AddProgramWeek, Tools::AddProgramDay, Tools::UpdateProgramDay,
        Tools::AddProgramLift, Tools::UpdateProgramLift, Tools::DeleteProgramLift,
        Tools::GenerateProgramWeek,
        # search + fetch satisfy ChatGPT's connector contract (composer + Deep Research).
        Tools::Search, Tools::Fetch
      ].freeze

      module_function

      def build(context)
        ::MCP::Server.new(
          name: Config.server_name,
          version: Config.server_version,
          instructions: Config.instructions,
          tools: TOOLS,
          server_context: context
        )
      end
    end
  end
end

