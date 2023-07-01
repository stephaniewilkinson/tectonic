# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.alter_table(:exercises) do
  rename_column(:icon, :icon_url)
end
