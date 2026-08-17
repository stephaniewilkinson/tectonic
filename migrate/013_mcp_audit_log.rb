# frozen_string_literal: true

Sequel.migration do
  # Append-only record of every MCP tool call worth remembering: always for writes
  # (on success and on failure alike), optionally for reads. `arguments` is jsonb so
  # a bad LLM session can be reconstructed and undone. `token_id` stays a live FK
  # because tokens are soft-revoked, never deleted.
  change do
    create_table(:mcp_audit_log) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      foreign_key :token_id, :api_tokens, null: false
      String :tool_name, null: false
      column :arguments, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      String :result_status, null: false
      String :error_message, text: true
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      index :account_id
    end
  end
end

