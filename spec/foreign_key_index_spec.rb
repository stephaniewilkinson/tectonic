# frozen_string_literal: true

require_relative 'spec_helper'

# Every foreign key wants an index, and Postgres does not give it one. #233.
#
# It creates indexes for primary keys and for unique constraints, and nothing else, so a
# `references` in a migration produces a constraint with no index behind it. Thirteen of
# ours were like that, four on the filters every page runs.
#
# Nothing visible goes wrong when this is missed, which is why it is asserted rather than
# noticed. Measured on a hundred thousand sets, the workouts list -- one query with a
# correlated EXISTS per row -- planned at a cost of 46,060 without the indexes and 491 with
# them, because the EXISTS was reading all hundred thousand rows of sets once per workout on
# the page. Every page rendered, every spec passed, and the only symptom was a number nobody
# was looking at.
#
# Read out of the catalogue rather than off a list kept here, so a table added later is
# covered the day it arrives instead of the day somebody remembers this file.
module ForeignKeyIndexes
  # A foreign key is covered when its column is the *first* column of some index. Postgres
  # can only use a composite index for a lookup that starts at its leading column, so
  # sets(workout_id, id) covers workout_id and an index on (id, workout_id) would not.
  UNINDEXED = <<~SQL
    select c.conrelid::regclass::text || '.' || a.attname
    from pg_constraint c
    join unnest(c.conkey) with ordinality k(attnum, ord) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
    where c.contype = 'f'
      and not exists (
        select 1 from pg_index i
        where i.indrelid = c.conrelid and a.attnum = any(i.indkey[0:0])
      )
    order by 1
  SQL
end

describe 'every foreign key' do
  it 'has an index leading with its column' do
    missing = DB[ForeignKeyIndexes::UNINDEXED].map { |row| row.values.first }

    assert_empty missing,
                 "these foreign keys have no index, so both the lookup and the parent's " \
                 "deletes scan the whole table:\n  #{missing.join("\n  ")}"
  end
end

# The two that are composite are composite on purpose: the query does not stop at the
# filter, and an index that carries the sort column answers both in one read. Pinned because
# narrowing either back to a single column would still pass the check above while quietly
# putting the sort back.
describe 'the indexes that carry a sort as well as a filter' do
  def leading(table, column)
    DB.indexes(table).values.select { |index| index[:columns].first == column }.map { |index| index[:columns] }
  end

  # #217 made order(:id) the ordering everywhere sets are listed.
  it 'orders sets by id within a workout' do
    assert_includes leading(:sets, :workout_id), %i[workout_id id]
  end

  # The workouts list reads backwards from today.
  it 'orders workouts by date within an account' do
    assert_includes leading(:workouts, :account_id), %i[account_id date]
  end
end

