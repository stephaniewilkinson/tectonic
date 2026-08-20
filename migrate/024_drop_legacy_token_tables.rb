# frozen_string_literal: true

Sequel.migration do
  # Retire every legacy token store now that all auth runs through rodauth-oauth (JWT
  # access tokens): the api_tokens PAT table, and the hand-rolled OAuth tables from the
  # superseded first attempt (oauth_clients / oauth_authorization_codes /
  # oauth_refresh_tokens, migrations 016-019). The FKs into api_tokens -- the audit
  # log's token_id, the provenance created_by_token_id, and oauth_refresh_tokens'
  # access_token_id -- were re-keyed in 022/023 or are dropped here first, so the tables
  # go cleanly. drop_table? tolerates a database where the hand-rolled attempt never ran.
  up do
    drop_table? :oauth_refresh_tokens
    drop_table? :oauth_authorization_codes
    drop_table? :oauth_clients
    drop_table :api_tokens
  end

  # Recreates api_tokens (migration 012's shape) so 022/023's down steps can re-add their
  # FKs to it. The hand-rolled OAuth tables are not restored: rolling back past this
  # point, to the superseded attempt, is not supported.
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

