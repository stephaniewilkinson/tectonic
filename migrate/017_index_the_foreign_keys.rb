# frozen_string_literal: true

# Postgres indexes primary keys and unique constraints. It does not index foreign keys.
# Thirteen of ours had none, and four of those are the filters every page in the app runs.
# #233.
#
# Measured on a hundred thousand sets and twenty thousand workouts. The workouts list is one
# query with a correlated EXISTS per row, and it planned at:
#
#   without these indexes   cost 46,060   -- Seq Scan on sets, 100,000 rows, once per workout
#   with them               cost    491   -- Index Scan using sets_workout_id_id_index
#
# Every page rendered either way and every spec passed either way. That is the point: the
# only symptom was a number nobody was looking at.
#
# Two are composite rather than single-column, because the query does not stop at the
# filter. The sets index carries id, which is the order #217 made every listing of sets use,
# so one index answers the where and the order by together instead of filtering and then
# sorting -- the Sort node disappears from the plan entirely. The workouts index carries
# date for the same reason; that list reads backwards from today.
#
# The rest are plain, and are here because an unindexed foreign key makes the *parent* slow
# too: deleting a workout has to scan every row of sets to know whether one points at it.
# That is why this covers all of them rather than only the four that are read often.
#
# CONCURRENTLY, which is why this is no_transaction and up/down rather than change. A plain
# CREATE INDEX takes a lock that blocks writes for its duration, and this runs as Render's
# preDeployCommand, where a blocked write is a failed request rather than a slow one. The
# cost is atomicity: these are fifteen separate statements now, so a failure part-way leaves
# some made and some not. That is recoverable -- a failed CREATE INDEX CONCURRENTLY leaves
# an index marked invalid, which is dropped and retried -- and it is the better trade for a
# migration that runs against a live database.
# The columns, as table => the index leading with that foreign key. Listed once and walked
# twice, so up and down cannot disagree about which fifteen this migration is responsible
# for -- a drop_index that quietly named fourteen of them would roll back to a database
# that still carried one.
FOREIGN_KEY_INDEXES = [
  [:sets, %i[workout_id id]],
  %i[sets exercise_id],
  %i[sets created_by_oauth_application_id],
  [:workouts, %i[account_id date]],
  %i[workouts program_day_id],
  %i[workouts created_by_oauth_application_id],
  %i[exercises account_id],
  %i[exercises created_by_oauth_application_id],
  %i[programs account_id],
  %i[program_days program_week_id],
  %i[program_lifts program_day_id],
  %i[program_lifts exercise_id],
  %i[oauth_grants account_id],
  %i[oauth_applications account_id],
  %i[mcp_audit_log oauth_application_id]
].freeze

Sequel.migration do
  no_transaction

  up do
    FOREIGN_KEY_INDEXES.each { |table, columns| add_index table, columns, concurrently: true }
  end

  down do
    FOREIGN_KEY_INDEXES.each { |table, columns| drop_index table, columns, concurrently: true }
  end
end

