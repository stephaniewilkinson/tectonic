# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.alter_table(:exercises) do
  rename_column(:warmup, :is_warmup)
end