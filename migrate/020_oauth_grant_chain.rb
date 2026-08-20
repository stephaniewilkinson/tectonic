# frozen_string_literal: true

Sequel.migration do
  # Ties a refresh token to the authorization grant it descends from, so a rotation
  # chain can be revoked as a unit. grant_id is minted once at the code exchange and
  # copied unchanged by every rotation, which is what lets reuse detection revoke the
  # whole family rather than only the row that was replayed. chain_expires_at is the
  # absolute deadline for the grant: rotation carries it forward untouched, so
  # refreshing forever can no longer extend one consent indefinitely.
  #
  # Rows that predate both columns each become their own family (the safe reading) and
  # keep their existing expiry as the chain deadline, after which both are NOT NULL.
  #
  # Both columns carry a database-side default, which is what makes this safe to apply
  # while the previous release is still serving: migrations run in preDeployCommand, so
  # for the length of the deploy the old code is still inserting refresh tokens that name
  # neither column. The defaults give those rows their own grant and a 90-day deadline
  # rather than a NOT NULL violation on every /token call.
  up do
    alter_table(:oauth_refresh_tokens) do
      add_column :grant_id, String, default: Sequel.lit('md5(random()::text)')
      add_column :chain_expires_at, Time, default: Sequel.lit("now() + interval '90 days'")
    end

    # Backfilled explicitly rather than left to the column defaults. chain_expires_at has
    # to come from each row's own expiry, and grant_id has to be distinct per row: were a
    # single value ever shared, those rows would read as one family and revoking any one
    # of them would revoke consents that have nothing to do with each other.
    from(:oauth_refresh_tokens).update(
      grant_id: Sequel.function(:md5, Sequel.cast(Sequel.function(:random), :text)),
      chain_expires_at: Sequel.function(:coalesce, :expires_at, Sequel::CURRENT_TIMESTAMP)
    )

    alter_table(:oauth_refresh_tokens) do
      set_column_not_null :grant_id
      set_column_not_null :chain_expires_at
    end
  end

  down do
    alter_table(:oauth_refresh_tokens) do
      drop_column :chain_expires_at
      drop_column :grant_id
    end
  end
end

