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

