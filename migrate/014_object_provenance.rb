# frozen_string_literal: true

Sequel.migration do
  # Records which API token (if any) created each exercise, workout, and set, and
  # when. `created_by_token_id` is a nullable FK to api_tokens: a null marks a row a
  # human made through the web UI, a value marks one an MCP tool made. `created_at`
  # is added with no default so existing rows stay null (their real creation time is
  # unknown); the default is set afterward so only future rows are stamped.
  up do
    %i[exercises workouts sets].each do |table|
      alter_table(table) do
        add_foreign_key :created_by_token_id, :api_tokens
        add_column :created_at, DateTime
        set_column_default :created_at, Sequel::CURRENT_TIMESTAMP
      end
    end
  end

  # Dropping each column also drops the foreign-key constraint it carries, so the
  # tables return to exactly their pre-migration shape.
  down do
    %i[exercises workouts sets].each do |table|
      alter_table(table) do
        drop_column :created_at
        drop_column :created_by_token_id
      end
    end
  end
end
