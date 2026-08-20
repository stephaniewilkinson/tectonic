# frozen_string_literal: true

require 'json'
require_relative '../tool'
require_relative 'support'
# Locator resolves a program: handle too, and ProgramView is what it renders one with.
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # ChatGPT's connector contract requires a `search` tool: it returns id/title/url
      # rows for the account's exercises and workouts, and each id feeds `fetch`. The
      # results are account-scoped through the context, so search never leaks a row.
      class Search < Tool
        tool_name 'search'
        description "Search the account's exercises (by name) and workouts (by date). " \
                    'Returns id/title/url rows; pass an id to fetch for the full object.'
        scope :read
        input_schema(
          type: 'object',
          properties: { query: { type: 'string' } },
          required: ['query'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          payload = { results: Locator.search(context, arguments[:query]) }
          ok(JSON.generate(payload), structured: payload)
        end
      end
    end
  end
end

