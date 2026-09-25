# frozen_string_literal: true

# The heart rate the watch recorded, reading by reading, so a set can be read against it. #656.
#
# #579 asked what the watch could add to a lifting session and answered its own biggest
# question with two requests: during a workout started on the watch, Withings' intraday series
# carries a heart rate every fifteen seconds or faster; outside one, every ten minutes. The
# per-workout average on `withings_workouts` already summarises the dense stretch; what it
# cannot say is anything about one set. These rows can.
#
# One row per reading rather than an array on the session, because the readings belong to the
# lifter and the clock rather than to any session: two sessions on one day, or a session moved
# to another date, read the same rows by time, and nothing has to be rewritten when a session
# does. Keyed by account and instant, so reading the same window twice writes nothing twice.
#
# `bpm` as Withings sends it, an integer. `model` because #579 found the device is the one fact
# that says whether a missing reading is a watch that did not record or one that cannot.
Sequel.migration do
  change do
    create_table(:heart_rates) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade
      DateTime :measured_at, null: false
      Integer :bpm, null: false
      String :source, null: false, default: 'withings'
      Integer :model
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      unique %i[account_id measured_at]
      constraint(:heart_rates_bpm_plausible) { (bpm > 20) & (bpm < 260) }
    end
  end
end

