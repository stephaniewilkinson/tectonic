# frozen_string_literal: true

Sequel.migration do
  # Bearer credentials for the MCP endpoint. Only the SHA-256 digest is stored, so
  # a database leak never yields a usable token. `scopes` is a Postgres text[]; a
  # token is soft-revoked by stamping `revoked_at`, never hard-deleted, so audit
  # rows keep a live foreign key to it.
  change do
    create_table(:api_tokens) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      String :token_digest, null: false, unique: true
      String :name
      column :scopes, 'text[]', null: false, default: Sequel.lit("'{}'")
      Time :last_used_at
      Time :expires_at
      Time :revoked_at
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

