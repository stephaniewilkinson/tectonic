# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:program_lifts) do
      primary_key :id
      foreign_key :program_day_id, :program_days, null: false
      foreign_key :exercise_id, :exercises, null: false
      Integer :position, { default: 0, null: false } # order within the day
      Integer :sets, null: false
      Integer :reps, null: false
      Integer :top_weight, null: false
      TrueClass :is_barbell, { default: false, null: false } # no warmups or plate math without this
      TrueClass :is_main, { default: false, null: false } # only main work gets rep conversion
      String :note
    end
  end
end

