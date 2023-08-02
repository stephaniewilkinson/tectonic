# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

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

Capybara.configure do |config|
  config.server = :puma
  config.run_server = true
  config.server_port = 9292
  config.default_driver = :firefox
  config.app_host = 'http://localhost:9292'
end
