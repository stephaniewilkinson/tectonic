# frozen_string_literal: true

require 'rake/testtask'
require 'dotenv/load'
require_relative '.env'

# Error reporting for everything rake runs. #386.
#
# `render.yaml` runs `rake db:migrate && rake library:exercises` on every deploy, before the
# new version accepts a single request, and until this line neither had any reporting at all:
# Sentry was initialised in config.ru, which the web server loads and rake does not. A
# migration that raised failed the deploy into a build log that is not searchable across
# deploys and that nobody is subscribed to -- which is how seven merged commits sat
# undeployed for six days in September while CI stayed green.
#
# `install_rake_reporting!` hooks the one place rake funnels a failed task through, so every
# task is covered rather than a list of the ones somebody remembered to wrap. It is a no-op
# where there is nothing to report to, which is every local run and every CI run.
#
# roda is required first because lib/ reopens `class Tectonic < Roda` and the superclass has
# to exist; migrator_db does the same thing further down for the same reason.
require 'roda'
require_relative 'lib/tectonic/error_reporting'
Tectonic::ErrorReporting.setup!
Tectonic::ErrorReporting.install_rake_reporting!

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

# The two halves of the suite, told apart by the module a describe includes when it wants
# a browser rather than by a list kept here, which would go stale the first time a describe
# started needing one. The cut is by file because a file is the unit rake hands minitest,
# so the two files that mix them -- program_ui_spec, where one describe of ten drives a
# browser, and session_swipe_spec, where two of six do not -- run whole with the browser
# half, and eleven rack_test describes ride along in the slower job.
BROWSER_SPECS, RACK_SPECS =
  Dir['spec/**/*_spec.rb'].partition { |file| File.read(file).include?('include BrowserSpec') }

namespace :test do
  # CI runs these two rather than the task above, so a browser that is discarded under the
  # driver on a loaded runner -- NoSuchWindowError, and the machine was busy, not the app
  # broken -- fails a job holding only the files that drive one, instead of taking the
  # report on the forty-odd that never open a window down with it. It does not stop the
  # flake happening; it stops it hiding everything else. `rake test` still runs the lot,
  # which is what a local run wants.
  Rake::TestTask.new(:rack) do |test|
    test.description = 'Run the specs that never open a browser'
    test.test_files = RACK_SPECS
    test.warning = false
  end

  Rake::TestTask.new(:browser) do |test|
    test.description = 'Run the specs that drive a real Firefox'
    test.test_files = BROWSER_SPECS
    test.warning = false
  end
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
# records a version far above anything this directory can produce. Left alone the migrator
# would try to recreate the tables in the first case and roll the schema back in the
# second, so both are stamped. An empty database is untouched: it needs the migration run.
#
# A database that has tables but not the baseline's tables is refused rather than stamped.
# Stamping one skips 001 and leaves it recorded as migrated with 001's tables missing,
# which raises nothing at the time and everything later.
def baseline(db)
  require_relative 'lib/tectonic/schema_baseline'
  return unless Tectonic::SchemaBaseline.populated?(db)

  refusal = Tectonic::SchemaBaseline.refusal(db)
  abort refusal if refusal

  db.create_table?(:schema_info) { Integer :version, default: 0, null: false }
  recorded = db[:schema_info].get(:version)
  return if Tectonic::SchemaBaseline.current?(recorded, BASELINE_VERSION, LATEST_VERSION)

  adopt(db, recorded)
end

# An empty schema_info takes a row; one already carrying a version has it corrected.
def adopt(db, recorded)
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

# The picture on the front page, taken from the app rather than from a phone.
#
# The one this replaced was three years old and it showed: a workout record that has since
# become the session screen, a bare "Squat" from before the exercise library existed, a
# date in July 2023, an iOS status bar and tab count, and -- on the page selling the app --
# a URL bar reading tectonic.onrender.com, which is the retired domain #251 is about.
#
# None of that was anyone's fault. Retaking it was a manual job nobody had written down,
# so it was never retaken. This is that job written down. It is not run by CI and does not
# need to be: nothing breaks when it rots, which is exactly how the last one rotted, so
# welcome_spec asserts the committed file against the markup that sizes it instead.
SCREENSHOT_DATABASE = 'tectonic_screenshot'
SCREENSHOT_PATH = 'assets/img/screenshot.jpeg'
# Firefox will not open a viewport narrower than 500 CSS px, and does not need to:
# Tailwind's `sm` breakpoint is 640, so at 500 every phone rule is in force and no `sm:`
# override is. The height is the window's rather than the page's -- Firefox keeps about
# 85px of it for its own chrome -- so the shot comes back shorter than asked and is
# cropped to a fixed size afterwards, which is what stops the committed file changing
# shape with a browser release.
SCREENSHOT_WINDOW = [500, 1100].freeze
SCREENSHOT_CROP = '500x992+0+0'
# Selenium writes a PNG whatever the filename says, so it gets a PNG name and the crop
# below is also the conversion. Shooting straight at the .jpeg produced a PNG called
# screenshot.jpeg, which every tool downstream read correctly and every human would not.
SCREENSHOT_RAW = 'tmp-screenshot.png'

namespace :assets do
  desc 'Retake the front page screenshot from the app itself, on a scratch database'
  task :screenshot do
    retake_screenshot
  end
end

# Builds a throwaway database, drives a headless Firefox through sign-up and into a
# seeded session, and crops what comes back.
def retake_screenshot
  abort 'Needs ImageMagick to crop: brew install imagemagick' unless system('command -v magick > /dev/null')

  reset_database(SCREENSHOT_DATABASE)
  sh({ 'DATABASE_URL' => "postgres:///#{SCREENSHOT_DATABASE}" }, 'bundle', 'exec', 'rake', 'library:exercises')
  # Assigned rather than defaulted, because the Rakefile resolved a URL from .env as it
  # loaded and app.rb below is what finally opens the connection. A task that has already
  # opened one -- `rake db:migrate assets:screenshot` -- would screenshot that database
  # instead, which is worth refusing rather than discovering in the committed file.
  abort 'Run this on its own: something in this process is already connected.' if defined?(DB)
  ENV['DATABASE_URL'] = "postgres:///#{SCREENSHOT_DATABASE}"
  shoot_session
  sh "magick #{SCREENSHOT_RAW} -crop #{SCREENSHOT_CROP} +repage -quality 82 -strip #{SCREENSHOT_PATH}"
  File.delete(SCREENSHOT_RAW)
  puts "Retook #{SCREENSHOT_PATH}"
end

# Signs up through the form rather than inserting an account, because the session screen
# is reached with a cookie and the sign-up is the shortest way to hold one.
def shoot_session
  require_relative 'app'
  require 'capybara/dsl'
  require 'securerandom'
  browse_headless
  session = Capybara::Session.new(:screenshot, Tectonic)
  session.current_window.resize_to(*SCREENSHOT_WINDOW)
  account_id = sign_up_in(session)
  session.visit "/workouts/#{seed_shown_session(account_id)}/session"
  session.assert_text 'Back Squat'
  session.save_screenshot(SCREENSHOT_RAW)
end

def browse_headless
  require 'selenium/webdriver'
  Capybara.server = :puma
  Capybara.register_driver :screenshot do |app|
    options = Selenium::WebDriver::Firefox::Options.new
    options.add_argument('-headless')
    Capybara::Selenium::Driver.new(app, browser: :firefox, options:)
  end
end

def sign_up_in(session)
  email = "screenshot-#{SecureRandom.hex(4)}@example.com"
  session.visit '/create-account'
  session.fill_in 'email', with: email
  session.fill_in 'password', with: SecureRandom.hex(8)
  session.click_on 'Sign up'
  DB[:accounts].where(email:).get(:id) or abort 'Sign-up did not take.'
end

# A squat day part way through: a ramp finished, one working set done and rated, two to
# go, and a second lift behind it so the swipe strip has an edge showing. Everything the
# session screen is for is in that -- a load, a rep count, the plates that make it, a
# Done button, and the RPE scale on the sets that take one.
def seed_shown_session(account_id)
  workout_id = DB[:workouts].insert(account_id:, date: Time.now)
  squat = { workout_id:, exercise_id: library_exercise('Back Squat'), is_barbell: true }
  [[45, 5, true], [135, 5, true], [185, 3, true], [225, 5, false]].each do |load, reps, warmup|
    DB[:sets].insert(**squat, weight: load, reps:, is_warmup: warmup, is_completed: true, rpe: (8 unless warmup))
  end
  2.times { DB[:sets].insert(**squat, weight: 225, reps: 5, is_warmup: false, is_completed: false) }
  bench = { workout_id:, exercise_id: library_exercise('Bench Press'), is_barbell: true }
  DB[:sets].insert(**bench, weight: 95, reps: 5, is_warmup: true, is_completed: false)
  DB[:sets].insert(**bench, weight: 155, reps: 5, is_warmup: false, is_completed: false)
  workout_id
end

def library_exercise(name)
  DB[:exercises].where(name:, account_id: nil).get(:id) or abort "The library has no #{name}."
end

# Folding one movement into another: everything logged against it and everything
# prescribed with it move across, and the empty row goes.
#
# Written for #267, which is one row of production data: `exercise:1` is a bare "Squat"
# predating the exercise library, sitting alongside Back Squat, High-Bar Squat and
# Low-Bar Squat. Over MCP that is a real ambiguity rather than an untidy list, because
# Resolver.exercise matches on the trimmed name and creates a private row when nothing
# matches -- so "squat" is a coin toss between a legacy row and whichever variation was
# meant, and a history question answered from the wrong one is answered wrongly and
# silently.
#
# A task rather than a migration, because it is one account's history rather than a
# schema change, and because whether those sets were back squats is a judgement only the
# person who lifted them can make. Written generally rather than hard-coded to that row:
# the same ambiguity turns up whenever somebody logs "Bench" for a year and then adds
# "Bench Press", and a one-off script for a recurring shape is a script somebody rewrites
# from memory the second time.
#
# DRY_RUN=1 says what it would do and writes nothing, which is the way to answer "how many
# sets does it have" -- the question #267 says to ask first. It counts every table the move
# touches since #367, not just the two this task originally moved; a dry run that listed
# only sets and lifts is how the cascade below stayed invisible for three migrations.
#
# The move itself is Tectonic::ExerciseMerge, in lib, because #367 was a second copy of the
# table list drifting from the schema -- and the spec had a third. One implementation, called
# by both.
# A namespace of its own rather than a task under db:, because this is the one thing in here
# that is about the database *not* being there.
namespace :backup do
  desc "Rehearse a restore from a dump: rake 'backup:drill[tectonic.dump]'"
  task :drill, [:dump] do |_task, args|
    restore_drill(args[:dump])
  end
end

# The half of #348 that a runbook cannot do on its own: actually restoring, and finding out
# whether what came back is a database or a directory of files that parse.
#
# A backup nobody has restored is a belief rather than a backup, and the ways it fails are
# quiet -- a dump taken with the wrong --format, an extension the restoring server does not
# have, a role the dump references and the target lacks. None of those announce themselves
# until the day they matter, which is the day nothing else is going well either.
#
# So this restores into a scratch database and then *asks the restored copy questions*: is
# it at the migration version this checkout expects, are the tables there, and did the rows
# arrive. A restore that exits zero having written nothing passes a naive drill and fails
# this one.
#
# Deliberately local and deliberately cheap, so it can be run on a laptop against a dump
# downloaded from Render rather than being a thing that needs a maintenance window. The
# scratch database is dropped and recreated each time, so the drill cannot pass by finding
# the data a previous run left behind -- which is the failure mode of every restore test
# that reuses a target.
DRILL_DATABASE = 'tectonic_restore_drill'

def restore_drill(dump)
  abort "Name a dump: rake 'db:drill[backup.dump]'" if dump.nil?
  abort "No such file: #{dump}" unless File.exist?(dump)

  puts "Restoring #{dump} into #{DRILL_DATABASE}..."
  sh "dropdb --if-exists #{DRILL_DATABASE}"
  sh "createdb #{DRILL_DATABASE}"
  load_dump(dump)
  report_drill(inspect_restored)
end

# pg_restore for a custom or directory dump, psql for plain SQL. Which one a dump needs is
# not something a person should have to remember mid-incident, and getting it wrong is the
# most common way a restore appears to do nothing: pg_restore given plain SQL exits without
# error and writes not one row.
def load_dump(dump)
  plain = dump.end_with?('.sql')
  command = plain ? "psql -q -d #{DRILL_DATABASE} -f" : "pg_restore --no-owner --no-privileges -d #{DRILL_DATABASE}"
  sh "#{command} #{dump}"
end

# What the restored copy actually contains. Read through a connection of its own rather than
# through the app's DB constant, which is already pointed somewhere else by the time a rake
# task runs.
def inspect_restored
  require 'sequel'
  Sequel.connect("postgres:///#{DRILL_DATABASE}") { |db| restored_facts(db, db.tables) }
end

# Guarded on the table existing, because the interesting case is the restore that produced
# some of the schema and not the rest -- which raises rather than reporting if asked
# straight, and a drill that crashes says less than one that says what is missing.
def restored_facts(db, tables)
  counted = %i[accounts workouts sets].to_h do |table|
    [table, (db[table].count if tables.include?(table))]
  end
  counted.merge(tables: tables.length,
                version: (db[:schema_info].get(:version) if tables.include?(:schema_info)))
end

# The drill's verdict, and it fails loudly rather than printing numbers for somebody to
# squint at. Three ways a restore can be wrong while appearing to work, each checked:
# nothing arrived, the schema is from a different era than this checkout, or the tables are
# there and empty.
def report_drill(found)
  puts "  schema version #{found[:version].inspect} (this checkout expects #{LATEST_VERSION})"
  puts "  #{found[:tables]} tables, #{found[:accounts].to_i} accounts, " \
       "#{found[:workouts].to_i} workouts, #{found[:sets].to_i} sets"
  problem = drill_verdict(found)
  abort problem if problem

  puts "PASSED: #{DRILL_DATABASE} is a working copy. Drop it with: dropdb #{DRILL_DATABASE}"
end

# Why the drill failed, or nil if it did not. Three ways a restore is wrong while appearing
# to work, in the order they are worth telling apart.
def drill_verdict(found)
  return 'FAILED: nothing was restored at all -- the dump did not load.' if found[:tables].zero?
  return schema_only_verdict if found[:version].nil?
  return stale_verdict(found[:version]) if found[:version] != LATEST_VERSION
  return 'FAILED: schema and version restored, but no accounts came with them.' if found[:accounts].to_i.zero?

  nil
end

# Tables but no rows, which is what a dump taken with pg_dump -s gives and is the most
# dangerous near-miss of the three: it restores without error, the app boots against it, and
# every account is simply gone. Worth its own sentence rather than being folded into "did
# not load", because the remedy is different -- the dump was taken wrongly, not corrupted.
def schema_only_verdict
  'FAILED: the tables are there but empty -- this looks like a schema-only dump ' \
    '(pg_dump -s). Take it without -s, or the restore brings back an empty app.'
end

# A restore that loaded but is from a different era than this checkout. Usable, and not the
# same as a failure -- so the message says which of the two it is rather than only "failed".
def stale_verdict(version)
  "FAILED: restored at version #{version}, but this checkout migrates to #{LATEST_VERSION}. " \
    'The data is intact; the app would need migrating before it could serve it.'
end

namespace :exercises do
  desc "Fold one movement into another and delete it: rake 'exercises:merge[Squat,Back Squat]'"
  task :merge, %i[from to] do |_task, args|
    merge_exercises(args[:from], args[:to])
  end
end

def merge_exercises(from_name, to_name)
  # The move itself, which knows every table that points at an exercise. Required here
  # rather than at the top of the file so a task that never touches a movement never opens a
  # connection by being loaded.
  require_relative 'lib/tectonic/exercise_merge'
  abort "Name both: rake 'exercises:merge[Squat,Back Squat]'" if from_name.nil? || to_name.nil?

  from = sole_exercise(from_name)
  to = sole_exercise(to_name)
  abort 'A movement cannot be folded into itself.' if from.id == to.id

  announce_merge(from, to)
  return puts 'DRY_RUN: nothing written.' if ENV['DRY_RUN']

  perform_merge(from, to)
end

# Exact name, and exactly one of it. A partial match would be convenient and is how the
# wrong movement's history gets moved: "Squat" is a prefix of four rows here, and the
# whole point of this task is that those four are worth telling apart.
# The movement a merge argument names: an exact name, or `id:N` where a name cannot say it.
#
# The id form is not a convenience. #475 has to fold a library `Deadlift` into a private
# `Deadlift` -- the private row carries 64 sets, a training max and seven program lifts, and
# the library one is empty -- and both are called `Deadlift`. By name that is ambiguous in
# both arguments and identical in the pair, so the two guards below refuse it twice over and
# the merge cannot be expressed at all. Exactly the merge most worth doing, since the whole
# reason the duplicate is dangerous is that a name cannot tell the two apart.
#
# `id:` rather than a bare number, so a movement somebody has named "12" is still reachable by
# its name and the two forms can never be confused for one another.
def sole_exercise(reference)
  given = reference.to_s.strip
  return exercise_by_id(given.delete_prefix('id:')) if given.start_with?('id:')

  found = Tectonic::Exercise.where(name: given).all
  abort "No movement named #{given.inspect}." if found.empty?
  abort ambiguous(given, found) if found.length > 1

  found.first
end

def ambiguous(given, found)
  "#{found.length} movements are named #{given.inspect} (ids #{found.map(&:id).join(', ')}). " \
    "Name one by id instead: rake 'exercises:merge[id:#{found.first.id},...]'."
end

def exercise_by_id(id)
  Tectonic::Exercise[id.to_i] || abort("No movement with id #{id.inspect}.")
end

# What would move, counted per table. A movement nothing points at says so outright rather
# than printing an empty list, since "nothing would move" is the answer that tells somebody
# they have named the wrong row.
def announce_merge(from, to)
  puts "#{from.name} (id #{from.id}#{', library row' if from.library?}) -> #{to.name} (id #{to.id})"
  carried = Tectonic::ExerciseMerge.tally(from)
  return puts '  Nothing points at it.' if carried.empty?

  carried.each { |line| puts "  #{line} would move." }
end

def perform_merge(from, to)
  Tectonic::ExerciseMerge.fold(from, to)
  puts "Folded #{from.name} into #{to.name}."
end

namespace :library do
  desc 'Load the built-in barbell exercise library (idempotent on name)'
  task :exercises do
    require_relative 'lib/tectonic/exercise_library'
    # Which names are new is read before the insert, because afterwards they are library rows
    # like any other and there is nothing left to tell them apart from the fifty-three that
    # were already here.
    added = Tectonic::Exercise::LIBRARY.reject { |name| Tectonic::Exercise.where(account_id: nil, name:).any? }
    created, skipped = Tectonic::Exercise.load_library
    puts "Library exercises: #{created} created, #{skipped} already present"
    report_library_collisions(added)
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

# Accounts that already had their own movement under a name this run just added. #477.
#
# This is how every duplicate on the reporting account was made: the library landed on top of
# training going back to 2023, five collisions in one deploy, and nothing said so. It cannot
# be prevented here -- a library row is global and the collision is per-account, so skipping
# the insert would deny the movement to everybody else -- and #474 is what makes it harmless.
# This is the part that was missing: the deploy is the only moment anybody could know.
#
# On stdout because that is the deploy log, and through the error reporter as a message rather
# than an exception, because a collision is not a failed deploy and must not read as one.
def report_library_collisions(added)
  collisions = Tectonic::Exercise.library_collisions(added)
  return if collisions.empty?

  collisions.each do |name, account_ids|
    puts "  #{name.inspect} collides with a movement #{account_ids.length} " \
         "#{account_ids.length == 1 ? 'account already has' : 'accounts already have'} of their own"
  end
  puts '  each of those keeps its own movement; the library row is there for everyone else'
end

# Reading a lifter's Withings history once, and offering what it finds to the sessions they
# have already logged.
#
# **This reverses a decision #520 wrote down.** That issue declines historical matching in so
# many words -- "matching an arbitrary past session is the hard version of this problem and
# this flow avoids it entirely" -- and the forward flow was built on that basis. The owner was
# asked afterwards and chose to have the hard version as well, as a second piece standing on
# the first. Deliberate, then, rather than an oversight, and what it reverses is the scope
# alone: every pairing is still a proposal, and the lifter still answers it.
#
# A task rather than anything that runs by itself, for two reasons and both are hard limits.
# `Withings::TIMEOUT` is ten seconds a call, so a walk over a decade can occupy a thread for
# minutes -- fine in a terminal, and not something to do inside a Puma worker that somebody's
# page view is queued behind. And it is deliberately nowhere near `preDeployCommand`, which
# runs before every single deploy: a release that reached out to Withings would fail whenever
# Withings had a bad afternoon, on a step whose job is to migrate a database.
#
# DRY_RUN=1 previews a run without writing, the same convention exercises:merge uses. It is
# not an estimate -- it is the real walk inside a transaction that always rolls back, so the
# numbers it prints are the numbers a real run would produce. It still makes the API calls,
# because there is no way to report on a history without reading it.
#
# The policy -- how far back to walk, which activity belongs to which session, what counts as
# already answered -- is Tectonic::WithingsBackfill, in lib, and is specced there. This prints.
namespace :withings do
  desc 'Import past Withings workouts and propose matches: rake withings:backfill ACCOUNT_ID=1 SINCE=2023 DRY_RUN=1'
  task :backfill do
    backfill_withings
  end
end

def backfill_withings
  require_relative 'lib/tectonic/workouts'
  require_relative 'lib/tectonic/withings_backfill'
  account_id = account_id_from(Tectonic::Workout)
  since = backfill_since
  dry_run = !ENV.fetch('DRY_RUN', nil).nil?
  puts "Reading Withings history for account #{account_id}#{" from #{since}" if since}#{' (DRY_RUN)' if dry_run}..."
  report_backfill(Tectonic::WithingsBackfill.run(account_id:, since:, dry_run:))
end

# The operator's bound, checked here rather than inside the policy, because a year typed
# wrongly is an argument problem and the answer to it is to say so and stop. `SINCE=23` is a
# plausible typo that would otherwise walk from the year 23 to this one, which is two
# thousand requests to Withings before anybody could intervene.
def backfill_since
  given = ENV.fetch('SINCE', nil)
  return nil unless given

  year = given.to_i
  abort "SINCE wants a four-digit year, not #{given.inspect}." unless year.between?(2000, Date.today.year)

  year
end

# What the run did, in the four numbers a lifter actually needs afterwards. Two of them are
# refusals to match, and they are reported rather than swallowed because a run that proposed
# nothing and a run that found nothing are different afternoons with the same silence.
def report_backfill(report)
  abort 'No Withings connection on that account. Connect one in settings first.' if report[:state] == :disconnected
  abort 'No stamped sessions to match against, so a history has nothing to be offered to.' if
    report[:state] == :no_sessions

  announce_walk(report)
  announce_proposals(report)
  puts 'DRY_RUN: nothing written. Run it again without DRY_RUN to keep these proposals.' if report[:dry_run]
end

# What came back, and -- loudly -- whether all of it did.
#
# A walk that stopped part way must never read as a finished one. Withings signal rate
# limiting as body status 601 and deliver it over HTTP 200, exactly like every other error
# they have, so a throttled fetch reaches this process as nil and would otherwise print as a
# tidy zero. On stderr, and naming the year it stopped at, because the remedy is to wait and
# run it again rather than to conclude that 2021 was a quiet year.
def announce_walk(report)
  years = report[:years]
  span = years.empty? ? 'no years' : "#{years.last}-#{years.first}"
  puts "Walked #{years.length} year(s) (#{span}): #{report[:found]} activity(ies) from Withings."
  return if report[:complete]

  warn "INCOMPLETE: Withings stopped answering at #{report[:stopped_at]}, so that year and everything " \
       'before it was never read. That is usually rate limiting (status 601), which arrives looking ' \
       'like success. Wait a few minutes and run this again; nothing already answered is re-proposed.'
end

# The pairing, and the two kinds of nothing.
#
# "No activity from your watch" is said plainly and without the forward flow's hedge. On the
# record page a session minutes old that has no activity is told to check back in a minute,
# because the watch's upload really is seconds to minutes behind. For a session from last
# March there is no upload on its way: absent is absent, and saying "yet" about it would be a
# promise nothing is going to keep.
def announce_proposals(report)
  # The path is still printed and is no longer the only way back, which is worth saying here
  # rather than leaving an operator to discover. Until #534 this line was the whole of the
  # app's signposting: a lifter who ran this, closed the terminal and came back on Sunday had
  # no route to their own questions but a remembered URL.
  puts "#{report[:proposed]} new proposal(s) waiting for an answer at /workouts/withings, " \
       'which the workouts list and the Withings block in settings both point at.'
  puts "#{report[:already_waiting]} session(s) already had one, and were left alone." if
    report[:already_waiting].positive?
  puts "#{report[:without_activity]} session(s) have no activity from your watch -- nothing was recorded " \
       'for them, which is an answer rather than something still to come.'
  puts "#{report[:activities_without_session]} activity(ies) the watch recorded match no session logged here."
end

