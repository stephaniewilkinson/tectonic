# frozen_string_literal: true

Sequel.migration do
  # Single-use authorization codes (~5 minute lifetime). Only the SHA-256 digest of the
  # code is stored. code_challenge/code_challenge_method carry the PKCE binding the token
  # endpoint verifies; used_at stamps the one redemption so a replay is refused. Each code
  # is bound to the account, client, redirect_uri, scopes, and resource it was issued for,
  # all of which the token endpoint re-checks before it mints an access token.
  change do
    create_table(:oauth_authorization_codes) do
      primary_key :id
      String :code_digest, null: false, unique: true
      foreign_key :account_id, :accounts, null: false
      String :client_id, null: false
      String :redirect_uri, null: false
      column :scopes, 'text[]', null: false, default: Sequel.lit("'{}'")
      String :code_challenge, null: false
      String :code_challenge_method, null: false
      String :resource
      Time :expires_at, null: false
      Time :used_at
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

