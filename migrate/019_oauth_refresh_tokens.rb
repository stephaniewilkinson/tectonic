# frozen_string_literal: true

Sequel.migration do
  # Refresh tokens, stored as digests and rotated on every use: redeeming one revokes it,
  # mints a fresh one, and records replaced_by_id, so presenting a rotated (or revoked)
  # token is an invalid_grant and a signal of theft. access_token_id links to the
  # api_tokens row minted with it; resource and scopes bound the access token a refresh
  # is allowed to mint. Soft-revoked (never deleted) so the rotation chain stays intact.
  change do
    create_table(:oauth_refresh_tokens) do
      primary_key :id
      String :token_digest, null: false, unique: true
      foreign_key :account_id, :accounts, null: false
      String :client_id, null: false
      column :scopes, 'text[]', null: false, default: Sequel.lit("'{}'")
      String :resource
      foreign_key :access_token_id, :api_tokens
      Integer :replaced_by_id
      Time :expires_at
      Time :revoked_at
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

