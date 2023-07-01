# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.alter_table(:exercises) do
  set_column_type :icon, String
end
