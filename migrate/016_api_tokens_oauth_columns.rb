# frozen_string_literal: true

Sequel.migration do
  # OAuth access tokens reuse the api_tokens table, so ApiToken.verify, RequestContext,
  # and the audit trail keep working unchanged. `kind` tells a personal access token
  # ('pat') apart from an OAuth-issued one ('oauth'); `client_id` records the OAuth
  # client a token was minted for and `resource` is its audience, which the MCP auth
  # middleware enforces so an OAuth token is only ever accepted at the endpoint it names.
  change do
    alter_table(:api_tokens) do
      add_column :kind, String, null: false, default: 'pat'
      add_column :client_id, String
      add_column :resource, String
    end
  end
end

