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
# allow_missing_migration_files tolerates the gap left by in-flight migrations that
# claimed 014/015 on unmerged branches; this branch's own migrations are 016-019.
def migrate_to(version)
  db = migrator_db
  baseline(db)
  Sequel::Migrator.run(db, 'migrate', target: version&.to_i, allow_missing_migration_files: true)
  puts "Database is at migration version #{db[:schema_info].get(:version)}"
end

# Reverses the most recently applied migration.
def rollback_one
  db = migrator_db
  abort 'Nothing to roll back: this database has never been migrated.' unless db.table_exists?(:schema_info)

  target = db[:schema_info].get(:version) - 1
  abort 'Already at version 0.' if target.negative?

  Sequel::Migrator.run(db, 'migrate', target:, allow_missing_migration_files: true)
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

namespace :library do
  desc 'Load the built-in barbell exercise library (idempotent on name)'
  task :exercises do
    require_relative 'lib/tectonic/exercise_library'
    created, skipped = Tectonic::Exercise.load_library
    puts "Library exercises: #{created} created, #{skipped} already present"
  end
end

namespace :oauth do
  desc "Delete spent OAuth rows older than a grace period: rake 'oauth:prune[30]'"
  task :prune, [:days] do |_task, args|
    prune_oauth(Integer(args[:days] || 30))
  end
end

namespace :mcp do
  namespace :token do
    desc "Mint an MCP bearer token: rake 'mcp:token:mint[read,write]' ACCOUNT_ID=1 NAME=laptop"
    task :mint, [:scopes] do |_task, args|
      # Rake splits `mint[read,write]` into a named arg plus extras, so gather both.
      mint_mcp_token([args[:scopes], *args.extras])
    end

    desc 'List MCP tokens (digest only, never the raw value)'
    task :list do
      list_mcp_tokens
    end

    desc "Soft-revoke an MCP token by id: rake 'mcp:token:revoke[3]'"
    task :revoke, [:id] do |_task, args|
      revoke_mcp_token(args[:id])
    end
  end
end

# Deletes OAuth rows that can never be used again, keeping `days` of them for forensics.
# The policy itself lives in OAuth::Retention so it can be tested; this only reports.
def prune_oauth(days)
  db = migrator_db
  require_relative 'lib/tectonic/oauth/retention'
  counts = Tectonic::OAuth::Retention.prune(db, Time.now - (days * 86_400))
  counts.each { |table, deleted| puts "#{table}: #{deleted} deleted" }
end

# Mints a token for ACCOUNT_ID (or the only account) with the given scopes and an
# optional NAME / EXPIRES_IN_DAYS, then prints the raw value once. It is never
# recoverable afterward, so the print is the whole point.
def mint_mcp_token(scope_args)
  require_relative 'lib/tectonic/api_token'
  minted = Tectonic::ApiToken.mint(account_id: account_id_from(Tectonic::ApiToken),
                                   scopes: mcp_scopes(scope_args),
                                   name: ENV.fetch('NAME', nil), expires_at: mcp_token_expiry)
  announce_minted_token(minted)
end

# Prints the new token's metadata plus its raw value, which is shown here once and
# is unrecoverable afterward.
def announce_minted_token(minted)
  record = minted.record
  puts "Minted token ##{record.id} for account #{record.account_id}, scopes: #{record.scope_list.join(', ')}"
  puts 'Raw token (shown once, copy it now):'
  puts minted.raw
end

# Scopes from the mixed rake arg forms, defaulting to read-only when none are given.
def mcp_scopes(scope_args)
  scopes = Array(scope_args).flat_map { |value| value.to_s.split(/[\s,]+/) }.reject(&:empty?)
  scopes.empty? ? ['read'] : scopes
end

# Optional expiry from EXPIRES_IN_DAYS; a token with none never expires on its own.
def mcp_token_expiry
  days = ENV.fetch('EXPIRES_IN_DAYS', nil)
  days ? Time.now + (days.to_i * 86_400) : nil
end

def list_mcp_tokens
  require_relative 'lib/tectonic/api_token'
  tokens = Tectonic::ApiToken.order(:id).all
  abort 'No MCP tokens yet.' if tokens.empty?
  tokens.each { |token| puts mcp_token_summary(token) }
end

def mcp_token_summary(token)
  used = token.last_used_at ? token.last_used_at.strftime('%Y-%m-%d') : 'never'
  "##{token.id} account=#{token.account_id} #{mcp_token_state(token)} " \
    "scopes=[#{token.scope_list.join(',')}] name=#{token.name || '-'} last_used=#{used}"
end

def mcp_token_state(token)
  return 'revoked' if token.revoked_at
  return 'expired' if token.expires_at && token.expires_at <= Time.now

  'active'
end

def revoke_mcp_token(id)
  require_relative 'lib/tectonic/api_token'
  token = Tectonic::ApiToken[id.to_i]
  abort "No token with id #{id}." unless token

  token.revoke!
  puts "Revoked token ##{token.id}."
end

# The seed needs an account to hang a program off. One account is the normal case
# in development, so only insist on being told which when there is a choice.
def seed_account_id
  account_id_from(Tectonic::Program)
end

# Resolves the account to act on: ACCOUNT_ID when given, otherwise the sole account,
# aborting when there is none or a choice to make. Any loaded model reaches accounts.
def account_id_from(model)
  return ENV['ACCOUNT_ID'].to_i if ENV['ACCOUNT_ID']

  ids = model.db[:accounts].select_map(:id)
  abort 'No accounts yet. Sign up first, or pass ACCOUNT_ID.' if ids.empty?
  abort "Several accounts exist (#{ids.join(', ')}). Pass ACCOUNT_ID." if ids.length > 1

  ids.first
end

