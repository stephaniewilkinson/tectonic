# frozen_string_literal: true

Sequel.migration do
  change do
    add_column :workouts, :rpe, Integer # session-level, 1-10, null until rated
  end
end

