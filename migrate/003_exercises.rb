# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.create_table(:exercises) do
  primary_key :id
  foreign_key :account_id, :accounts, null: false
  String :name, null: false # Benchpress
end
