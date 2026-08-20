# frozen_string_literal: true

# A program used to be one week of one block, holding a bare `week` integer and no dates
# at all, so week 1 and week 2 of the same block were unrelated rows that happened to
# share a name. This makes a program the block: it gains the date it starts on, and the
# weeks inside it become rows of their own that days hang off, so a block knows how long
# it is, when each of its weeks falls, and which of them is a deload before anyone reads
# its loads.
#
# The steps are constants holding lambdas rather than one migration block, the shape the
# baseline settled on: a single block long enough to do this trips Metrics/BlockLength,
# and every obvious way of shortening it trips a different cop instead.
#
# Each existing program becomes a block of one week, numbered from the old `week` column,
# with its days repointed at that row. Nothing is merged: two rows written as weeks of
# one block stay two blocks of one week here, because the old schema recorded nothing
# that could prove they belonged together beyond a shared name, and guessing wrong would
# silently reshape somebody's plan.
PROGRAM_WEEKS_TABLE = lambda do |db|
  db.create_table(:program_weeks) do
    primary_key :id
    foreign_key :program_id, :programs, null: false
    Integer :number, null: false
    TrueClass :is_deload, null: false, default: false
    String :notes

    index %i[program_id number], unique: true
  end
end

# Existing rows have no start date to recover -- it was never stored -- so they adopt the
# Monday of the week this migration runs, which keeps the column non-null and puts an
# already-written week in the present rather than at some arbitrary epoch.
PROGRAM_BLOCK_DATES = lambda do |db|
  monday = Sequel.cast(Sequel.function(:date_trunc, 'week', Sequel::CURRENT_DATE), :date)
  db.add_column :programs, :start_date, Date
  db.from(:programs).update(start_date: monday)
  db.alter_table(:programs) { set_column_not_null :start_date }
end

# One week row per program, taking its number from the column it replaces. A program that
# never recorded a week is week 1: the number was nullable and a block starts somewhere.
PROGRAM_WEEK_ROWS = lambda do |db|
  db.from(:program_weeks).insert(%i[program_id number],
                                 db.from(:programs).select(:id, Sequel.function(:coalesce, :week, 1)))
end

# Days move from the program to the week, which is the whole point: a day now belongs to
# one week of the block rather than to a row that was itself a week.
PROGRAM_DAYS_TO_WEEKS = lambda do |db|
  weeks = db.from(:program_weeks).select(:id).limit(1)
  db.add_column :program_days, :program_week_id, Integer
  db.from(:program_days).update(program_week_id: weeks.where(program_id: Sequel[:program_days][:program_id]))
  db.alter_table(:program_days) do
    set_column_not_null :program_week_id
    add_foreign_key [:program_week_id], :program_weeks
    drop_column :program_id
  end
end

# Down keeps the lowest week number of each block and drops the rest, lossy in the way any
# reversal of a one-to-many is: it restores the shape, not the weeks authored after the
# split, and not which of them was a deload.
PROGRAM_WEEKS_TO_DAYS = lambda do |db|
  lowest = db.from(:program_weeks).select { min(:number) }
  owners = db.from(:program_weeks).select(:program_id).limit(1)
  db.add_column :programs, :week, Integer
  db.from(:programs).update(week: lowest.where(program_id: Sequel[:programs][:id]))
  db.add_column :program_days, :program_id, Integer
  db.from(:program_days).update(program_id: owners.where(id: Sequel[:program_days][:program_week_id]))
  db.alter_table(:program_days) do
    set_column_not_null :program_id
    add_foreign_key [:program_id], :programs
    drop_column :program_week_id
  end
end

Sequel.migration do
  up do
    PROGRAM_WEEKS_TABLE.call(self)
    PROGRAM_BLOCK_DATES.call(self)
    PROGRAM_WEEK_ROWS.call(self)
    PROGRAM_DAYS_TO_WEEKS.call(self)
    drop_column :programs, :week
  end

  down do
    PROGRAM_WEEKS_TO_DAYS.call(self)
    drop_table(:program_weeks)
    drop_column :programs, :start_date
  end
end

