# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
# The suite names its own database rather than inheriting whichever one the shell, a
# .env file or the Rakefile has already chosen for the app. It has to: these specs
# create accounts, workouts, exercises, sets, OAuth grants and audit rows, and the
# teardown below empties every table between tests, so a run pointed at the development
# database would no longer merely seed it -- it would empty it. Inheriting is how a bare
# `rake test` came to seed the development database in the first place: the Rakefile
# requires .env.rb, which resolves a URL from RACK_ENV, long before this line runs. The
# connection is opened by app.rb below, so setting it here is early enough.
# TEST_DATABASE_URL is for a run that wants a database of its own, which is what two
# suites at once need.
ENV['DATABASE_URL'] = ENV.fetch('TEST_DATABASE_URL', 'postgres:///tectonic_test')
# The OAuth resource identifier the MCP endpoint verifies tokens against and advertises
# in its discovery document; tests sign and expect tokens for this audience.
ENV['MCP_PUBLIC_BASE_URL'] ||= 'https://example.org'

# bcrypt is deliberately slow, and in a test suite that is the whole cost of the run.
#
# The default cost is 12, which is about 200ms a hash on this machine -- the point of the
# algorithm, and right in production, where it happens once when somebody logs in. Here it
# happened roughly four times per test: the helpers that seed an account hash a password,
# and every login then *verifies* against that hash, which costs the same again because
# verification cost is carried by the stored hash rather than chosen by the verifier.
#
# Rodauth already knew this -- it uses BCrypt::Engine::MIN_COST when RACK_ENV is test -- so
# the accounts it creates through the sign-up form were always cheap. What was not cheap
# was every account a spec inserted with BCrypt::Password.create directly, and every login
# against one of those. Fourteen spec files do that.
#
# Setting the engine's cost here covers both halves: those hashes are created at cost 4 and
# therefore verified at cost 4 too. It is scoped to the suite -- production reads
# BCrypt::Engine::DEFAULT_COST through Rodauth and never loads this file -- and it is the
# same trade Rails makes in its own test environment. It took `rake test:rack` from about
# five minutes to under thirty seconds.
require 'bcrypt'
require 'securerandom'
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

# require 'dotenv/load' #keeping this here until i need it later
require 'minitest/autorun'
require 'minitest/capybara'
require 'minitest/pride'
require 'rack/test'

require_relative '../app'

# Every test starts against empty tables, because no spec here cleans up by hand and rows
# that outlive their test are how a spec comes to pass for the wrong reason: it reads an
# account or an exercise an earlier file left behind, and then fails on its own, or under
# a different seed, with nothing in it to say why. Rows only ever accumulated before this,
# too, so `Exercise.load_library` and the OAuth queries ran against tables that grew with
# every run and `rake db:reset` was the only way back.
#
# Deletes rather than a transaction rolled back around each test, which is the usual
# answer and cannot work here. The browser specs drive the app on a Puma server in another
# thread, and that thread takes its own connection out of the pool: rows written inside
# the test's own uncommitted transaction do not exist as far as the server is concerned,
# so the page the browser fetches comes back without them. Sharing one connection between
# the two threads is the standard way round that, and trades an ordering bug for a race --
# two threads issuing queries on one Postgres connection with nothing serialising them.
module CleanDatabase
  # Children before parents, which is what the foreign keys require; a wrong order raises
  # rather than leaks. test_isolation_spec asserts this still names every table, since a
  # migration that adds one and forgets it here would go back to leaking quietly.
  TABLES = %i[
    sets program_lifts withings_workouts workouts program_days program_weeks programs
    mcp_audit_log oauth_grants account_plates account_dumbbell_plates
    account_training_maxes account_training_max_statements
    account_goals account_exercise_rests health_metrics account_withings
    account_remember_keys account_password_reset_keys account_verification_keys exercises
    oauth_applications accounts
  ].freeze

  # Prepended below rather than included, because Minitest::Test defines after_teardown
  # itself and a copy from an included module would sit behind it and never run. The
  # delete happens after `super` so that Capybara has already reset its session: the
  # cookie a browser is holding names an account that is about to stop existing.
  def after_teardown
    super
    CleanDatabase.clean
  end

  def self.clean
    DB.transaction do
      TABLES.each do |table|
        rows = DB[table]
        # The built-in library is not test data. It is what `rake library:exercises`
        # leaves in a deployed database before anybody signs up, the spec files that read
        # it seed it once at load time, and reseeding those fifty-odd rows between every
        # test would buy nothing. A movement with an account behind it is somebody's,
        # and goes.
        rows = rows.exclude(account_id: nil) if table == :exercises
        rows.delete
      end
    end
  end
end

Minitest::Test.prepend CleanDatabase
# And once before anything runs, because the database this run inherited was very likely
# filled by a run that predates the teardown above, and a spec that asserts what a test
# starts with would fail on the first one for a reason nothing in this run caused.
CleanDatabase.clean

Capybara.app = Tectonic
Capybara.register_driver :firefox do |app|
  Capybara::Selenium::Driver.new app, browser: :firefox
end

# The headless one is now actually headless. It was registered as a byte-for-byte copy of
# the driver above, so the name promised a window would not open and then opened one, and
# anybody reaching for it to quieten a run found it did nothing.
Capybara.register_driver :headless_firefox do |app|
  # Required here rather than at the top of the file so a run that never asks for a
  # browser never loads selenium at all. capybara-selenium defers it too, which is why
  # naming Selenium::WebDriver in this block without the require raised NameError while
  # the driver above, which only ever calls into Capybara, did not.
  require 'selenium/webdriver'
  options = Selenium::WebDriver::Firefox::Options.new
  options.add_argument('-headless')
  Capybara::Selenium::Driver.new(app, browser: :firefox, options:)
end

# HEADED=1 puts the window back, which is the only way to watch a spec argue with the
# session screen. Everything else runs with no window, including CI, which never had a
# display to open one on in the first place.
Capybara.javascript_driver = ENV['HEADED'] ? :firefox : :headless_firefox

# No port is named, so Capybara takes a free one for the run and every visit is
# relative to the server it started. Pinning 9292 here, and repeating it in app_host,
# meant a second suite bound the port the first was already serving on, which is a
# browser spec failing for a reason that has nothing to do with the app -- and it would
# do the same to CI the day its jobs run in parallel.
Capybara.configure do |config|
  config.server = :puma
  config.run_server = true
  # rack_test rather than a browser, because most of what these specs do is fill a form
  # and read the markup that comes back, and none of that needs a rendering engine. It
  # runs in this process: no Selenium, no driver binary, no port, no window. A browser
  # starts for the specs that genuinely need one and those say so, by assigning
  # javascript_driver at the top of the describe -- which is the whole list of places in
  # this suite where JavaScript is load-bearing.
  config.default_driver = :rack_test
end

# A describe that genuinely needs a rendering engine says so by including this. It names
# the driver by role rather than by name, so the HEADED switch above reaches every one of
# them and no spec hard-codes :firefox; and it puts the default back afterwards, because
# current_driver is global and a describe that left the browser selected would hand it to
# whichever file the seed happened to order next.
#
# The list of includers is the honest answer to "where is JavaScript load-bearing here":
# the session screen and its swipe strip, which htmx swaps under; the sign-up walk in
# system_spec; and the escaping specs, which have to ask a real parser whether a name
# became an element. The block editor was on this list until its delete stopped asking.
module BrowserSpec
  def before_setup
    super
    Capybara.current_driver = Capybara.javascript_driver
  end

  def after_teardown
    forget_held_taps
    Capybara.use_default_driver
    super
  end

  # The session screen's write queue, emptied between tests for the same reason the tables
  # above are. #542 holds a tap that failed in IndexedDB so that it survives the tab being
  # closed -- which is the point of it, and which means it also survives the end of a test.
  # Capybara's session reset clears cookies and nothing else, so a tap held by one example
  # was still there for the next: it flushed on that example's first page load, the set it
  # named had been deleted by the teardown here, the server refused it, and a spec that had
  # nothing to do with any of this found "1 set did not save" on its screen. That is a spec
  # failing for a reason nothing in it caused, which is the shape this file already exists
  # to prevent.
  #
  # Before Capybara resets, because after it the browser is on about:blank and storage is
  # keyed by origin -- the deletion would be of a database belonging to nowhere.
  #
  # Waited on rather than fired and forgotten, since the deletion is asynchronous and the
  # next example's page load would otherwise race it. The page's own connection is what
  # would block it, and the script there closes on versionchange precisely so that
  # something asking to delete this database is not left waiting on a tab nobody is looking
  # at any more.
  def forget_held_taps
    Capybara.current_session.evaluate_async_script(<<~JS)
      var done = arguments[0];
      if (!window.indexedDB) { return done(); }
      var request = window.indexedDB.deleteDatabase('tectonic');
      request.onsuccess = done;
      request.onerror = done;
      request.onblocked = done;
    JS
  rescue StandardError
    # A test that never opened a page, or a browser that has already gone. Neither leaves
    # anything behind to clear, and neither is worth failing a green example over.
    nil
  end
end

# A signed-in Capybara session, which eight spec files needed and each of which built its own
# by walking the sign-up form. #575 put a confirmation email in the middle of that walk and
# broke all eight at once, which is the argument for there being one of these rather than
# eight: the flow those files depend on is "be signed in", and none of them was written to
# have an opinion about how an account comes to exist.
#
# So the row is written directly and only the sign-in is driven. Writing an account straight
# into the table is what fifty-odd other files here already do, and it is the case
# migrate/051's default of an open status exists to keep working. The sign-up walk itself is
# pinned end to end in confirming_the_address_spec, and driven through a real Firefox --
# including the email and the link -- in system_spec, which is where a flow with three pages
# and a message in it belongs.
#
# The address and the password can be named by a caller that needs to use them again, and the
# account's id comes back because that is what every caller did with it.
module SignedInBrowser
  def sign_in_as_somebody_new(email: "#{SecureRandom.hex}@gmail.com", password: SecureRandom.hex)
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password))
    visit '/login'
    fill_in 'email', with: email
    fill_in 'password', with: password
    click_on 'Sign in'
    DB[:accounts].where(email:).get(:id)
  end
end

Minitest::Test.include SignedInBrowser

