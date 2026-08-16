# frozen_string_literal: true

require_relative '../tool'

class Tectonic < Roda
  module MCP
    module Tools
      # The one proof tool for this pass. It reports who the request resolved to,
      # which exercises auth, per-account scoping, error handling, and audit wiring
      # end to end. It is also the worked example in the README for adding a tool:
      # subclass Tool, name it, declare a schema and a scope, and write `perform`.
      class Whoami < Tool
        tool_name 'whoami'
        description 'Report the authenticated account id, email, and granted scopes.'
        scope :read
        input_schema(type: 'object', properties: {}, additionalProperties: false)

        # Reads identity straight off the resolved context; it never names an account,
        # because it cannot. `arguments` is unused, so it is swallowed by `**`.
        def self.perform(context:, **)
          ok(
            "You are account #{context.account_id} (#{context.email}). " \
            "Granted scopes: #{context.scopes.join(', ')}.",
            structured: { account_id: context.account_id, email: context.email, scopes: context.scopes }
          )
        end
      end
    end
  end
end

