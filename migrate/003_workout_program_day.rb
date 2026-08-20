# frozen_string_literal: true

# The generator wrote a workout with nothing but an account and a date, so the moment a
# week was generated the link between a program day and the workout it produced was
# gone: a generated session and one typed in by hand were the same shape of row. That
# made a plan unrecoverable -- there was no query behind "how did week 2 go" -- and it
# made the generator unable to recognise its own output, so idempotency had to key on
# the date alone and any unrelated workout logged that day suppressed generation for it.
#
# The column is nullable because most workouts have no program behind them and never
# will: a session logged by hand or over MCP leaves it null, and that null is the
# distinction the workouts list reads to tell a plan from a record of training. It goes
# unindexed, like every other column on this table: the lookups that use it are already
# filtered to one account's workouts, and an index built here would have to be created
# concurrently, outside the transaction this migration runs in, to be worth having.
Sequel.migration do
  up do
    add_column :workouts, :program_day_id, Integer
    alter_table(:workouts) { add_foreign_key [:program_day_id], :program_days }
  end

  down do
    drop_column :workouts, :program_day_id
  end
end

