# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/schema_baseline'

Baseline = Tectonic::SchemaBaseline

# A stand-in for a database, answering only what the check asks of one. Real databases in
# these shapes are what the migrator meets, but building them takes a CREATE and a DROP
# per case and the logic under test only ever asks which tables exist.
class FakeDatabase
  def initialize(*tables)
    @tables = tables
  end

  def table_exists?(name)
    @tables.include?(name)
  end
end

def baseline_database
  FakeDatabase.new(:accounts, :oauth_applications, :oauth_grants)
end

describe 'SchemaBaseline.populated?' do
  it 'is false for a database with nothing in it, which simply needs migrating' do
    refute Baseline.populated?(FakeDatabase.new)
  end

  it 'is true once there are accounts' do
    assert Baseline.populated?(baseline_database)
  end
end

describe 'SchemaBaseline.carries_baseline?' do
  it 'accepts a database carrying the tables the baseline creates' do
    assert Baseline.carries_baseline?(baseline_database)
  end

  # The case that corrupted a development database: accounts present, so it looked
  # adoptable, but 001's tables missing, so stamping it skipped their creation.
  it 'rejects a database that predates the OAuth tables' do
    refute Baseline.carries_baseline?(FakeDatabase.new(:accounts, :api_tokens))
  end

  # A database still carrying the table the old numbering dropped has not reached the
  # baseline either, whatever else it has.
  it 'rejects a database still carrying the legacy token table' do
    refute Baseline.carries_baseline?(FakeDatabase.new(:accounts, :oauth_applications, :api_tokens))
  end
end

describe 'SchemaBaseline.refusal' do
  it 'says nothing about a database it can adopt' do
    assert_nil Baseline.refusal(baseline_database)
  end

  # The message has to name what is wrong, because the remedy is always the same and an
  # operator deserves to know what they are rebuilding away from.
  it 'names the missing table and the legacy one' do
    refusal = Baseline.refusal(FakeDatabase.new(:accounts, :api_tokens))

    assert_includes refusal, 'no oauth_applications table'
    assert_includes refusal, 'a legacy api_tokens table'
    assert_includes refusal, 'db:reset'
  end
end

# Adopting on anything but the baseline was harmless while the baseline was the only
# migration and became a bug the moment a second existed: a database at version 2 was
# stamped back to 1 on every run and the migrator replayed a migration already applied.
describe 'SchemaBaseline.current?' do
  it 'leaves a version inside the sequence alone' do
    assert Baseline.current?(1, 1, 6)
    assert Baseline.current?(6, 1, 6)
    assert Baseline.current?(2, 1, 6)
  end

  it 'adopts a version the sequence cannot have produced' do
    refute Baseline.current?(24, 1, 6)
    refute Baseline.current?(0, 1, 6)
  end

  it 'adopts a database that records no version at all' do
    refute Baseline.current?(nil, 1, 6)
  end
end

