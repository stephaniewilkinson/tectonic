# frozen_string_literal: true

Sequel.migration do
  # Point the audit log at the OAuth client (the LLM) that made the call, now that
  # access tokens are rodauth-oauth JWTs rather than api_tokens rows. Nullable so a
  # call whose client cannot be resolved still leaves an audit trail.
  up do
    alter_table(:mcp_audit_log) do
      add_foreign_key :oauth_application_id, :oauth_applications
      drop_column :token_id
    end
  end

  down do
    alter_table(:mcp_audit_log) do
      add_foreign_key :token_id, :api_tokens
      drop_column :oauth_application_id
    end
  end
end

