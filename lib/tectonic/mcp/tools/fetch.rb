# frozen_string_literal: true

require 'json'
require_relative '../tool'
require_relative 'support'
# Locator resolves a program: handle too, and ProgramView is what it renders one with.
require_relative 'program_support'

class Tectonic < Roda
  module MCP
    module Tools
      # ChatGPT's connector contract requires a `fetch` tool: it returns the full object
      # (id/title/text/url) for an id a prior `search` returned. The lookup runs through
      # the account-scoped datasets, so an id for another account's row resolves to
      # nothing rather than leaking it.
      class Fetch < Tool
        tool_name 'fetch'
        description 'Fetch one object (an exercise or workout) by the id a prior search returned.'
        scope :read
        input_schema(
          type: 'object',
          properties: { id: { type: 'string' } },
          required: ['id'], additionalProperties: false
        )

        def self.perform(context:, arguments:)
          document = Locator.fetch(context, arguments[:id])
          raise Tool::Refusal, "No object with id #{arguments[:id].inspect}." unless document

          ok(JSON.generate(document), structured: document)
        end
      end
    end
  end
end

