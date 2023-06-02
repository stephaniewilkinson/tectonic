# frozen_string_literal: true

require_relative '../lib/db'

DB.create_table(:exercises) do
  primary_key :id
  String :name # Benchpress
  Integer :goal_weight
end
