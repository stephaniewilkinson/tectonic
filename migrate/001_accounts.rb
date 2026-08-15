# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id
      File :profile_picture
      String :email, null: false
      String :password_hash, null: false
      Time :created_on, { default: Time.now.utc, null: false }
    end
  end
end