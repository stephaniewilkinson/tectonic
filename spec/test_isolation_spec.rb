# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'uri'

# Seeded here, as four other spec files do, so the library specs below say the same thing
# whether this file runs alone or in the middle of a full suite.
Tectonic::Exercise.load_library

# Where the suite is pointed matters more than most configuration does, because it writes
# accounts, workouts, grants and audit rows, and empties every table between tests. It used
# to inherit whatever database the app had been pointed at, which is how a bare `rake test`
# came to seed the development one -- and emptying that one would be worse again.
describe 'the database the suite runs against' do
  it 'is never the development or production one, whatever DATABASE_URL held' do
    database = DB.opts[:database].to_s

    refute_includes database, 'development'
    refute_includes database, 'production'
  end

  it 'is the one TEST_DATABASE_URL names, so concurrent runs can have one each' do
    named = ENV.fetch('TEST_DATABASE_URL', nil)
    skip 'this run did not ask for a database of its own' unless named

    assert_equal URI.parse(named).path.delete_prefix('/'), DB.opts[:database].to_s
  end
end

describe 'what one test leaves behind for the next' do
  # Every other file in this suite signs accounts up and writes workouts and sets, and on
  # a full run the seed has put some of them before this one, so these pass only because
  # the teardown in spec_helper empties the tables between tests.
  it 'is nothing: the tables a spec writes to are empty when the next test starts' do
    written = CleanDatabase::TABLES - [:exercises]
    left_behind = written.reject { |table| DB[table].empty? }

    assert_empty left_behind
  end

  # The one deliberate exception. Library rows are what a deployed database holds before
  # anybody signs up, so they survive; a movement belonging to an account does not.
  it 'is the built-in exercise library, and nothing else in the exercises table' do
    assert_equal Tectonic::Exercise::LIBRARY.length, DB[:exercises].count
  end
end

# A migration that adds a table and forgets the list would leak its rows silently, which
# is the failure the teardown exists to stop. schema_info is the migrator's own.
describe 'the list of tables the teardown empties' do
  it 'names every table in the database' do
    assert_equal (DB.tables - [:schema_info]).sort, CleanDatabase::TABLES.sort
  end
end

describe 'the Capybara server' do
  # Capybara takes a free port when none is named. Naming one is what made a second
  # suite collide with the first, and app_host repeated the number, so fixing either
  # without the other would have sent the browser to a server that was not there.
  it 'is left to find its own port rather than pinned to one' do
    assert_nil Capybara.server_port
    assert_nil Capybara.app_host
  end
end

