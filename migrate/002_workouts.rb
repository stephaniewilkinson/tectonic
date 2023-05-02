# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:workouts) do
  primary_key :id
  foreign_key :user_id, :users
  Time :date
  Time :created_on, { default: Time.now.utc, null: false }
end
