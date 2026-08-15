# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:workouts) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      File :photo
      Time :date, { default: Time.now.utc, null: false }
      Time :created_on, { default: Time.now.utc, null: false }
    end
  end
end

