# frozen_string_literal: true

Sequel.migration do
  # The lookup that answers "what has this account connected, and to whom": the index
  # behind OAuthRefreshToken.grants_for, which a connected-applications screen reads.
  # Concurrent and idempotent for the same reasons as 021, and separate from it so that
  # one failed build does not strand the other.
  no_transaction

  up do
    alter_table(:oauth_refresh_tokens) do
      add_index %i[account_id client_id], concurrently: true, if_not_exists: true
    end
  end

  down do
    alter_table(:oauth_refresh_tokens) do
      drop_index %i[account_id client_id], concurrently: true, if_exists: true
    end
  end
end

