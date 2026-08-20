# frozen_string_literal: true

Sequel.migration do
  # The lookup revocation performs: by grant_id, when a reused token takes its whole family
  # down. Built concurrently so it cannot lock out /token on a live deployment, which means
  # it cannot run inside a transaction, which is why it is not part of 020.
  #
  # IF NOT EXISTS / IF EXISTS because a concurrent build is not transactional: a cancelled
  # one leaves an INVALID index behind, and without these a retry of the deploy would fail
  # forever on the leftover. Recovery from an INVALID index is
  # `DROP INDEX CONCURRENTLY oauth_refresh_tokens_grant_id_index` and then re-running.
  # One index per migration, so a partial run still advances the schema version.
  no_transaction

  up do
    alter_table(:oauth_refresh_tokens) do
      add_index :grant_id, concurrently: true, if_not_exists: true
    end
  end

  down do
    alter_table(:oauth_refresh_tokens) do
      drop_index :grant_id, concurrently: true, if_exists: true
    end
  end
end

