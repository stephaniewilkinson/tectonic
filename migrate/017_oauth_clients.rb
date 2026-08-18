# frozen_string_literal: true

Sequel.migration do
  # A registered OAuth client (RFC 7591 dynamic registration). Public clients such as
  # claude.ai register with token_endpoint_auth_method 'none' and hold no secret; the
  # optional client_secret_digest exists only for a future confidential client and, like
  # every credential here, is a digest, never the clear value. redirect_uris is the exact
  # allow-list the authorize endpoint matches an incoming redirect_uri against.
  change do
    create_table(:oauth_clients) do
      primary_key :id
      String :client_id, null: false, unique: true
      String :client_name
      column :redirect_uris, 'text[]', null: false, default: Sequel.lit("'{}'")
      column :grant_types, 'text[]', null: false, default: Sequel.lit("'{}'")
      column :response_types, 'text[]', null: false, default: Sequel.lit("'{}'")
      String :token_endpoint_auth_method, null: false, default: 'none'
      column :scopes, 'text[]', null: false, default: Sequel.lit("'{}'")
      String :client_secret_digest
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

