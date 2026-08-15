# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:programs) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      String :name, null: false # Block 0
      Integer :block
      Integer :week
      String :notes
      Integer :preferred_reps # nil keeps each lift's prescribed reps
      TrueClass :is_ascending, { default: true, null: false }
    end
  end
end