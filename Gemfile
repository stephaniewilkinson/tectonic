# frozen_string_literal: true

source 'https://rubygems.org'

ruby File.read(File.join(__dir__, '.ruby-version')).chomp.delete_prefix('ruby-')

gem 'bcrypt'
gem 'chartkick'
gem 'dotenv'
gem 'erubi'
gem 'http'
gem 'puma'
gem 'rack'
gem 'rackup'
gem 'rake'
gem 'roda'
gem 'roda-http-auth'
gem 'rodauth'
gem 'rollbar'
gem 'sequel'
gem 'sequel_pg'
gem 'tilt'

group :development do
  gem 'better_html'
  gem 'erb_lint', require: false
  gem 'rubocop'
  gem 'rubocop-performance'
end

group :test do
  gem 'capybara-selenium'
  gem 'minitest'
  gem 'minitest-capybara'
  gem 'rack-test'
end
