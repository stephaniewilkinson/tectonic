# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# What a row is stamped with when it is given no stamp of its own. #574.
#
# `accounts.created_on` and `workouts.created_on` were declared `default: Time.now.utc`, which
# reads like a clock and is not one: Sequel evaluates that expression once, while the migration
# is running, and the instant it produces goes into the column as a literal. Production's
# defaults are therefore `'2023-06-16 04:03:51.973907'` and `'2023-06-16 04:03:52.814183'`, and
# every row written since has taken the constant. All 410 accounts and all 54 workouts claim to
# have been created on the same June morning. Not most of them. All of them.
#
# 001 already corrected the declaration -- its comment names this exact trap -- and that
# correction reached every database built from the file and no database that predates it.
# Production was stamped as carrying the baseline rather than rebuilt from it, which is the
# right thing to do with a squash and is also why the fix never arrived. So the suite has been
# asserting the corrected schema, on a database built from the corrected file, for as long as
# the bug has been in production. That is worth stating plainly: **a spec that only ever sees a
# database this repo built cannot tell you what the deployed one defaults to.** What these
# specs can do is fix the shape a migration has to produce, so the columns that carry a frozen
# instant are gone from both and a new one cannot be introduced by the same mistake.
#
# Five of the seven checks below fail on today's schema and two are guards. The failing ones
# are the two columns that go and the three about the account's new `created_at`; the guards
# are `workouts.date`, which carries a frozen literal in production and a correct one here, and
# the sweep over every table at the bottom, which is the check that would have caught this in
# 2023 and is cheap enough to keep forever.
module CreationStamps
  # A default that was an instant once. Postgres prints a literal timestamp default as a
  # quoted date -- `'2023-06-16 04:03:51.973907'::timestamp without time zone` -- where a
  # working one is the bare word CURRENT_TIMESTAMP, possibly with arithmetic around it. The
  # date is looked for anywhere in the expression rather than at the front, so a default that
  # buries one inside a cast or an interval is caught too.
  FROZEN_INSTANT = /'\d{4}-\d{2}-\d{2}/

  module_function

  # Every column in the database whose default is an instant that has already passed, named
  # with the default itself, because "accounts.created_on" alone does not tell anybody what is
  # wrong with it.
  def frozen_defaults
    DB.tables.sort.flat_map do |table|
      DB.schema(table).filter_map do |column, column_spec|
        "#{table}.#{column} defaults to #{column_spec[:default]}" if
          column_spec[:default].to_s.match?(FROZEN_INSTANT)
      end
    end
  end

  def columns(table) = DB.schema(table).map(&:first)

  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex(8)}@example.com", password_hash: 'x')
end

describe 'the column that recorded nothing' do
  it 'is gone from accounts, which has a creation date that moves instead' do
    refute_includes CreationStamps.columns(:accounts), :created_on
  end

  # Pure redundancy, and the one place the two could be compared: `workouts.created_at`
  # defaults to CURRENT_TIMESTAMP and always has, which is why it disagreed with `created_on`
  # on 36 of the 54 rows. It disagreed by being right. Nothing in lib, app.rb or views ever
  # read `created_on`, so this one leaves with nothing to replace it.
  it 'is gone from workouts, where created_at was already saying it honestly' do
    refute_includes CreationStamps.columns(:workouts), :created_on
  end
end

describe 'when an account was created' do
  it 'is recorded' do
    assert_includes CreationStamps.columns(:accounts), :created_at
  end

  # Read against the database's own clock rather than Ruby's, so the assertion is about the
  # default being evaluated at insert time and not about two machines agreeing on a zone. A
  # frozen default fails this by three years, not by a rounding error.
  it 'is the instant the account was inserted, not one the schema was born carrying' do
    before = DB.get(Sequel::CURRENT_TIMESTAMP)
    id = CreationStamps.an_account

    assert_operator DB[:accounts].where(id:).get(:created_at), :>=, before
  end

  # The decision #574 turns on, written where it can be checked. The 410 accounts already in
  # production have no true creation date anywhere in the database -- `created_on` cannot
  # supply one, being the same instant for all of them -- so they are left saying nothing.
  # Null here means "created before anybody was recording it", and anything that reports an
  # account's age has to handle that rather than assume a date is there.
  it 'may be nothing at all, which is what an account created before this was recorded has' do
    id = DB[:accounts].insert(email: "#{SecureRandom.hex(8)}@example.com", password_hash: 'x', created_at: nil)

    assert_nil DB[:accounts].where(id:).get(:created_at)
  end
end

describe 'the instant a row is given when it is given none' do
  # Harmless today, because every writer in the app supplies a date, and a trap for the first
  # one that does not: on production this column defaults to the same June morning, so a
  # session inserted without a date would be filed three years back.
  it 'dates a session written today today' do
    before = DB.get(Sequel::CURRENT_TIMESTAMP)
    id = DB[:workouts].insert(account_id: CreationStamps.an_account)

    assert_operator DB[:workouts].where(id:).get(:date), :>=, before
  end

  # The general form of the bug, over the whole catalogue rather than a list kept here, so a
  # column added next year is covered the day it arrives. `default: Time.now.utc` looks
  # entirely reasonable in a migration and produces a column that is wrong on every row it
  # will ever have; this is the one cheap place that can tell the difference.
  it 'never hands one that has already passed' do
    frozen = CreationStamps.frozen_defaults

    assert_empty frozen,
                 'these columns default to an instant rather than to the clock, so every row ' \
                 "written without one gets the same answer forever:\n  #{frozen.join("\n  ")}"
  end
end

