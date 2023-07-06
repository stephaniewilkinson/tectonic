# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.create_table(:exercises) do
  primary_key :id
  foreign_key :account_id, :accounts, null: false
  String :name, null: false # Benchpress
  String :icon_url # https://example.com/benchpress.png
end
