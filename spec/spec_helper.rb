# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'
# The suite names its own database rather than inheriting whichever one the shell, a
# .env file or the Rakefile has already chosen for the app. It has to: these specs
# create accounts, workouts, exercises, sets, OAuth grants and audit rows and clean none
# of them up, and inheriting is how a bare `rake test` came to seed the development
# database -- the Rakefile requires .env.rb, which resolves a URL from RACK_ENV, long
# before this line runs. The connection is opened by app.rb below, so setting it here is
# early enough. TEST_DATABASE_URL is for a run that wants a database of its own, which
# is what two suites at once need.
ENV['DATABASE_URL'] = ENV.fetch('TEST_DATABASE_URL', 'postgres:///tectonic_test')
# The OAuth resource identifier the MCP endpoint verifies tokens against and advertises
# in its discovery document; tests sign and expect tokens for this audience.
ENV['MCP_PUBLIC_BASE_URL'] ||= 'https://example.org'

# require 'dotenv/load' #keeping this here until i need it later
require 'minitest/autorun'
require 'minitest/capybara'
require 'minitest/pride'
require 'rack/test'

require_relative '../app'

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
    Capybara.use_default_driver
    super
  end
end

