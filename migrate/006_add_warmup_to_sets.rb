# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.alter_table(:sets) do
  add_column :warmup, TrueClass, { default: false, null: false }
end
