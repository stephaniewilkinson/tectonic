# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:workouts) do
  primary_key :id
  foreign_key :account_id, :accounts, null: false
  File :photo
  Time :date
  Time :created_on, { default: Time.now.utc, null: false }
end
