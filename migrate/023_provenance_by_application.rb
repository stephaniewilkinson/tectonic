# frozen_string_literal: true

Sequel.migration do
  # Re-key object provenance from the retired api_tokens to the OAuth client, so
  # "which LLM created this" names the stable registered client rather than a single
  # token. A human-made row keeps a null FK exactly as before.
  up do
    %i[exercises workouts sets].each do |table|
      alter_table(table) do
        add_foreign_key :created_by_oauth_application_id, :oauth_applications
        drop_column :created_by_token_id
      end
    end
  end

  down do
    %i[exercises workouts sets].each do |table|
      alter_table(table) do
        add_foreign_key :created_by_token_id, :api_tokens
        drop_column :created_by_oauth_application_id
      end
    end
  end
end

