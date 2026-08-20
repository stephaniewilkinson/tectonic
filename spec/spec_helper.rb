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

Capybara.register_driver :headless_firefox do |app|
  Capybara::Selenium::Driver.new app, browser: :firefox
end

Capybara.javascript_driver = :firefox

# No port is named, so Capybara takes a free one for the run and every visit is
# relative to the server it started. Pinning 9292 here, and repeating it in app_host,
# meant a second suite bound the port the first was already serving on, which is a
# browser spec failing for a reason that has nothing to do with the app -- and it would
# do the same to CI the day its jobs run in parallel.
Capybara.configure do |config|
  config.server = :puma
  config.run_server = true
  config.default_driver = :firefox
end

