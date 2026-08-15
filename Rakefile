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

# Migrates to a target version, or to the latest when given none.
def migrate_to(version)
  db = migrator_db
  baseline(db)
  Sequel::Migrator.run(db, 'migrate', target: version&.to_i)
  puts "Database is at migration version #{db[:schema_info].get(:version)}"
end

# Reverses the most recently applied migration.
def rollback_one
  db = migrator_db
  abort 'Nothing to roll back: this database has never been migrated.' unless db.table_exists?(:schema_info)

  target = db[:schema_info].get(:version) - 1
  abort 'Already at version 0.' if target.negative?

  Sequel::Migrator.run(db, 'migrate', target:)
  puts "Database is at migration version #{db[:schema_info].get(:version)}"
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
    migrate_to(args[:version])
  end

  desc 'Roll back the most recent migration'
  task :rollback do
    rollback_one
  end
end

namespace :program do
  desc 'Seed the block 0 week 1 program, for ACCOUNT_ID or the only account'
  task :seed do
    require_relative 'lib/tectonic/program_seed'
    program = Tectonic::ProgramSeed.seed(seed_account_id)
    puts "Program #{program.id}: #{program.name} week #{program.week}, #{program.program_days.count} day(s)"
  end

  desc "Generate a week of workouts: rake 'program:generate[2026-08-17]' PROGRAM_ID=1"
  task :generate, [:week_start] do |_task, args|
    require_relative 'lib/tectonic/program_generator'
    program = Tectonic::Program[ENV.fetch('PROGRAM_ID', nil)] || Tectonic::Program.first
    abort 'No program to generate. Run rake program:seed first.' unless program

    week_start = args[:week_start] ? Date.parse(args[:week_start]) : Date.today
    Tectonic::ProgramGenerator.new(program).generate(week_start).each do |workout|
      puts "#{workout.date.strftime('%A %b %-d')}: workout #{workout.id}, #{workout.sets.count} sets"
    end
  end
end

# The seed needs an account to hang a program off. One account is the normal case
# in development, so only insist on being told which when there is a choice.
def seed_account_id
  return ENV['ACCOUNT_ID'].to_i if ENV['ACCOUNT_ID']

  ids = Tectonic::Program.db[:accounts].select_map(:id)
  abort 'No accounts yet. Sign up first, or pass ACCOUNT_ID.' if ids.empty?
  abort "Several accounts exist (#{ids.join(', ')}). Pass ACCOUNT_ID." if ids.length > 1

  ids.first
end

