# frozen_string_literal: true

Sequel.migration do
  # A nil account_id marks a library exercise, shared with every account. The
  # partial unique index keeps the library free of duplicate names. The down
  # migration can only restore NOT NULL once every library row is gone.
  # CREATE INDEX CONCURRENTLY cannot run inside a transaction, so opt out.
  no_transaction

  up do
    alter_table(:exercises) do
      set_column_allow_null :account_id
    end
    add_index :exercises, :name, unique: true, concurrently: true,
                                 where: { account_id: nil }, name: :exercises_library_name_key
  end

  down do
    drop_index :exercises, :name, concurrently: true, name: :exercises_library_name_key
    alter_table(:exercises) do
      set_column_not_null :account_id
    end
  end
end

