# frozen_string_literal: true

require 'mcp'
require_relative 'config'
require_relative 'tools/whoami'

class Tectonic < Roda
  module MCP
    # Builds the MCP server for one request, wired to that request's account context.
    # The mcp gem fixes server_context at construction and stateless mode holds no
    # state between requests, so a fresh server per request is how per-account scoping
    # is reached without any shared mutable state.
    module ServerFactory
      # Every tool the server exposes. Registering a new tool is adding its class here
      # (and requiring it above); auth, scoping, validation, and auditing come from the
      # base class.
      TOOLS = [Tools::Whoami].freeze

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

