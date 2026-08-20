# frozen_string_literal: true

require 'rake/testtask'
require 'dotenv/load'
require_relative '.env'

# The migration the squashed schema lives in. Everything up to and including the old
# 024 was folded into it, so any database already carrying that schema is at this
# version by definition, whatever number it happens to record.
BASELINE_VERSION = 1
# The highest version this migrate directory can bring a database to, read from the
# files so it cannot drift as migrations are added. It is what tells an old-numbering
# version apart from a current one, which matters the moment a second migration exists.
LATEST_VERSION = Dir[File.join(__dir__, 'migrate', '*.rb')].map { |file| File.basename(file).to_i }.max

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

# Brings a database that already carries the squashed schema to the baseline's version
# without running it. Two kinds arrive here: one predating the migrator, which has the
# tables but no schema_info to prove it, and one migrated under the old numbering, which
# records a version far above anything this directory can produce. Left alone the
# migrator would try to recreate the tables in the first case and to roll the schema
# back in the second, so both are stamped instead. A database with no tables at all is
# untouched: it needs the migration actually run.
#
# A version inside the current sequence is left exactly as it is. Adopting on anything
# but the baseline was harmless while the baseline was the only migration and became a
# bug the moment a second one existed: a database at version 2 was stamped back to 1 on
# every run and the migrator then replayed a migration it had already applied. The one
# version this cannot distinguish is an old-numbering database whose number the sequence
# has since grown past, which stops mattering long before it reaches 24.
def baseline(db)
  return unless db.table_exists?(:accounts)

  db.create_table?(:schema_info) { Integer :version, default: 0, null: false }
  recorded = db[:schema_info].get(:version)
  return if recorded&.between?(BASELINE_VERSION, LATEST_VERSION)

  # An empty schema_info takes a row; one already carrying a version has it corrected.
  if recorded.nil?
    db[:schema_info].insert(version: BASELINE_VERSION)
  else
    db[:schema_info].update(version: BASELINE_VERSION)
  end
  puts "Adopted the squashed baseline: version #{recorded || 'none'} -> #{BASELINE_VERSION}"
end

# Migrates to a target version, or to the latest when given none.
def migrate_to(version)
  db = migrator_db
  baseline(db)
  Sequel::Migrator.run(db, 'migrate', target: version&.to_i)
  puts "Database is at migration version #{db[:schema_info].get(:version)}"
end

# The way back from a database a test run has seeded, which is what a bare `rake test`
# did to development until the suite began naming its own. Rebuilding is the cure rather
# than hunting the rows down, since one run leaves accounts, workouts, exercises, sets,
# grants and audit rows scattered across half the schema. A name can be given so a
# scratch database is rebuilt the same way, and the migration runs in a subprocess
# because this process resolved its own connection from the environment as it loaded.
def reset_database(name)
  database = name || 'tectonic_development'
  sh "dropdb --if-exists #{database}"
  sh "createdb #{database}"
  sh({ 'DATABASE_URL' => "postgres:///#{database}" }, 'bundle', 'exec', 'rake', 'db:migrate')
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

# The two databases a checkout keeps locally: one to develop against, and the one the
# suite connects to when a run has not named a database of its own.
LOCAL_DATABASES = %w[tectonic_development tectonic_test].freeze

namespace :db do
  desc 'Create the tectonic postgres user'
  task :create_user do
    sh 'createuser -U postgres tectonic || true'
  end

  desc 'Setup development and test databases'
  task create: %i[create_user] do
    LOCAL_DATABASES.each { |database| sh "createdb -U postgres -O tectonic #{database}" }
  end

  desc 'Drop the development and test databases'
  task :drop do
    LOCAL_DATABASES.each { |database| sh "dropdb #{database}" }
  end

  desc "Drop, recreate and migrate a database, development by default: rake 'db:reset[tectonic_scratch]'"
  task :reset, [:database] do |_task, args|
    reset_database(args[:database])
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
  desc 'Seed the block 0 program, for ACCOUNT_ID or the only account'
  task :seed do
    require_relative 'lib/tectonic/program_seed'
    program = Tectonic::ProgramSeed.seed(seed_account_id)
    puts "Program #{program.id}: #{program.name}, #{program.weeks} week(s) from #{program.start_date}"
  end

  desc "Generate a week of workouts: rake 'program:generate[1]' PROGRAM_ID=1, the current week by default"
  task :generate, [:week] do |_task, args|
    require_relative 'lib/tectonic/program_generator'
    generate_program_week(args[:week])
  end
end

# Generates one week of a block, defaulting to the week today falls in. The block's
# start date already fixes when each week runs, so the caller no longer has to work out
# which Monday to name -- and a block that has not started or has already finished has
# no current week, which is worth saying rather than guessing the nearest one.
def generate_program_week(number)
  program = Tectonic::Program[ENV.fetch('PROGRAM_ID', nil)] || Tectonic::Program.first
  abort 'No program to generate. Run rake program:seed first.' unless program

  week = number ? program.week(number.to_i) : program.week_on
  abort missing_week_message(program, number) unless week
  announce_generated(Tectonic::ProgramGenerator.new(program).generate(week.number))
end

def announce_generated(workouts)
  workouts.each do |workout|
    puts "#{workout.date.strftime('%A %b %-d')}: workout #{workout.id}, #{workout.sets.count} sets"
  end
end

def missing_week_message(program, number)
  return "Program #{program.id} has no week #{number}; it has #{program.weeks}." if number

  "Program #{program.id} runs #{program.weeks} week(s) from #{program.start_date}, which does not cover today. " \
    "Name a week: rake 'program:generate[1]'."
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
  namespace :client do
    desc "Register a headless OAuth client (LLM): rake 'oauth:client:register[Name]' ACCOUNT_ID=1"
    task :register, [:name] do |_task, args|
      register_oauth_client(args[:name])
    end
  end

  desc "Delete spent grants and abandoned clients, with a grace period: rake 'oauth:prune[30]'"
  task :prune, [:days] do |_task, args|
    prune_oauth(args[:days])
  end
end

# Collects what open registration leaves behind. The policy -- what counts as spent,
# and what has to be kept because something still points at it -- lives in Retention
# and is specced there; this only reports what it did.
def prune_oauth(days)
  require_relative 'lib/tectonic/oauth/retention'
  days = (days || Tectonic::OAuth::Retention::DEFAULT_DAYS).to_i
  pruned = Tectonic::OAuth::Retention.prune(days:)
  puts "Pruned #{pruned[:grants]} grant(s) and #{pruned[:applications]} client(s) spent for #{days}+ days."
end

# Registers a confidential OAuth client bound to ACCOUNT_ID (or the only account) and
# prints its client_id and secret once. A headless caller exchanges them via the
# client-credentials grant at /token for a short-lived JWT access token; interactive
# clients (claude.ai, ChatGPT) never need this -- they register themselves over DCR.
def register_oauth_client(name)
  require_relative 'lib/tectonic/oauth_application'
  require 'securerandom'
  require 'bcrypt'
  secret = SecureRandom.urlsafe_base64(32)
  app = Tectonic::OAuthApplication.create(
    name: name || 'Headless client', account_id: account_id_from(Tectonic::OAuthApplication),
    client_id: SecureRandom.uuid, client_secret: BCrypt::Password.create(secret), scopes: 'read write'
  )
  announce_oauth_client(app, secret)
end

# Prints the new client's id and its secret, which is shown here once (the row keeps
# only a bcrypt hash), so the print is the whole point.
def announce_oauth_client(app, secret)
  puts "Registered client ##{app.id} '#{app.name}' for account #{app.account_id}, scopes: #{app.scopes}"
  puts "client_id:     #{app.client_id}"
  puts 'client_secret (shown once, copy it now):'
  puts secret
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

