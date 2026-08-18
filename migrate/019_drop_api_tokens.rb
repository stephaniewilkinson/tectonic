# frozen_string_literal: true

Sequel.migration do
  # Retire the personal-access-token store: all MCP auth now runs through rodauth-oauth
  # (JWT access tokens), so nothing reads api_tokens anymore. Its former FKs -- the
  # audit log's token_id and the provenance created_by_token_id -- were already re-keyed
  # to oauth_applications in 017/018, so the table drops cleanly.
  up do
    drop_table :api_tokens
  end

  # Recreates the table from migration 012's shape (empty; the tokens themselves are
  # gone for good).
  down do
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

