# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.create_table(:account_remember_keys) do
  foreign_key :id, :accounts, primary_key: true, type: :Bignum
  String :key, null: false
  deadline_opts = { null: false, default: Sequel.date_add(Sequel::CURRENT_TIMESTAMP, days: 14) }
  DateTime :deadline, deadline_opts
end
