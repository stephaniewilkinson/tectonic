# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.alter_table(:exercises) do
  add_column :icon, File
end
