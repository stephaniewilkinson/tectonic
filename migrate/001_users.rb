# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:users) do
  primary_key :id
  Time :created_on, { default: Time.now.utc, null: false }
end
