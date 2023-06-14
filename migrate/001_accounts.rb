# frozen_string_literal: true

require_relative '../lib/tectonic/db'

DB.create_table(:accounts) do
  primary_key :id
  File :profile_picture
  String :email
  String :password_hash, null: false
  Time :created_on, { default: Time.now.utc, null: false }
end
