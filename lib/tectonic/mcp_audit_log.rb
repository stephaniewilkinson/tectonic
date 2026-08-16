# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # One row per audited MCP tool call. Written by the tool base class, never by a
  # tool directly, so auditing is structural rather than something each tool has to
  # remember. Reopened as a plain Sequel model on the singular `mcp_audit_log` table.
  class McpAuditLog < Sequel::Model(:mcp_audit_log)
    # Appends an audit row from a resolved request context. `arguments` is the tool's
    # raw argument hash, stored as jsonb; `status` is one of success / error / refused;
    # `error` carries the refuse-and-explain message on the non-success paths.
    def self.record(context:, tool_name:, arguments:, status:, error: nil)
      insert(
        account_id: context.account_id,
        token_id: context.token_id,
        tool_name:,
        arguments: Sequel.pg_jsonb(arguments || {}),
        result_status: status.to_s,
        error_message: error,
        created_at: Time.now
      )
    end
  end
end

