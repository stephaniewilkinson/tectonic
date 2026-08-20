# frozen_string_literal: true

Sequel.migration do
  # One authorization/refresh grant issued to a client for an account. Access tokens
  # are signed JWTs (oauth_jwt) and are not stored; `token`/`refresh_token` hold
  # bcrypt hashes for the non-JWT and refresh paths. `expires_in` is the expiry
  # timestamp (rodauth-oauth's column name), `resource` binds the grant to the MCP
  # audience (RFC 8707), and the code_challenge columns carry PKCE.
  up do
    create_table(:oauth_grants) do
      primary_key :id
      foreign_key :account_id, :accounts
      foreign_key :oauth_application_id, :oauth_applications
      String :type
      String :code
      String :token
      String :refresh_token
      DateTime :expires_in, null: false
      String :redirect_uri
      DateTime :revoked_at
      String :scopes, null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      String :access_type, null: false, default: 'offline'
      String :code_challenge
      String :code_challenge_method
      String :resource
      index %i[oauth_application_id code], unique: true
      index :token, unique: true
      index :refresh_token, unique: true
    end
  end

  down { drop_table? :oauth_grants }
end

