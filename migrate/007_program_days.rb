# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:program_days) do
      primary_key :id
      foreign_key :program_id, :programs, null: false
      Integer :weekday, null: false # 0-6, matching Date#wday, so 0 is Sunday
      String :focus # Squat
    end
  end
end

