# frozen_string_literal: true

require 'rake/testtask'
require 'dotenv/load'
require_relative '.env'

# Migrations 001-005 predate the migrator, so a database created before it exists
# already has those tables but no schema_info row to prove it.
BASELINE_VERSION = 5

task default: :test

Rake::TestTask.new do |test|
  test.pattern = 'spec/**/*_spec.rb'
  test.warning = false
end

# Connects and loads the migration extension. Kept out of the task bodies so tasks
# that never touch the database don't open a connection just by being loaded.
def migrator_db
  require_relative 'lib/tectonic/db'
  Sequel.extension :migration
  DB
end

# A database that predates the migrator reads as version 0, so the migrator would
# try to recreate tables that are already there. Stamp it at the baseline instead.
def baseline(db)
  return if db.table_exists?(:schema_info) || !db.table_exists?(:accounts)

  db.create_table(:schema_info) { Integer :version, default: 0, null: false }
  db[:schema_info].insert(version: BASELINE_VERSION)
  puts "Stamped existing database at migration version #{BASELINE_VERSION}"
end

namespace :db do
  desc 'Create the tectonic postgres user'
  task :create_user do
    sh 'createuser -U postgres tectonic || true'
  end

  desc 'Setup development and test databases'
  task create: %i[create_user] do
    sh 'createdb -U postgres -O tectonic tectonic_development'
    sh 'createdb -U postgres -O tectonic tectonic_test'
  end

  desc 'Drop the development and test databases'
  task :drop do
    sh 'dropdb tectonic_development'
    sh 'dropdb tectonic_test'
  end

  desc "Migrate the database at DATABASE_URL, optionally to a version: rake 'db:migrate[5]'"
  task :migrate, [:version] do |_task, args|
    db = migrator_db
    baseline(db)
    Sequel::Migrator.run(db, 'migrate', target: args[:version]&.to_i)
    puts "Database is at migration version #{db[:schema_info].get(:version)}"
  end

  desc 'Roll back the most recent migration'
  task :rollback do
    db = migrator_db
    abort 'Nothing to roll back: this database has never been migrated.' unless db.table_exists?(:schema_info)

    target = db[:schema_info].get(:version) - 1
    abort 'Already at version 0.' if target.negative?

    Sequel::Migrator.run(db, 'migrate', target:)
    puts "Database is at migration version #{db[:schema_info].get(:version)}"
  end
end