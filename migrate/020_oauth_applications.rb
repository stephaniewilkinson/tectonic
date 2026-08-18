# frozen_string_literal: true

Sequel.migration do
  # Registered OAuth clients (the LLMs that connect to the MCP endpoint), the store
  # behind rodauth-oauth's authorization server. `client_secret` holds a bcrypt hash,
  # never the secret itself. `account_id` is nullable: a client registered through
  # dynamic client registration (RFC 7591) has no owning user. The trailing string
  # columns are the optional DCR metadata rodauth-oauth reads and writes.
  up do
    create_table(:oauth_applications) do
      primary_key :id
      foreign_key :account_id, :accounts
      String :name, null: false
      String :redirect_uri
      String :scopes, null: false
      String :client_id, null: false
      String :client_secret, null: false
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      %i[description homepage_url registration_access_token token_endpoint_auth_method
         grant_types response_types client_uri logo_uri tos_uri policy_uri jwks_uri
         jwks contacts software_id software_version].each { |c| String c }
      index :client_id, unique: true
      index :client_secret, unique: true
    end
  end

  down { drop_table? :oauth_applications }
end

