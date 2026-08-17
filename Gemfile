# frozen_string_literal: true

source 'https://rubygems.org'

ruby File.read(File.join(__dir__, '.ruby-version')).chomp.delete_prefix('ruby-')

gem 'bcrypt'
gem 'chartkick'
gem 'dotenv'
gem 'erubi'
gem 'http'
# Pinned exactly: this gem is pre-1.0-ish and its API shifts between minor
# releases. >= 0.23.0 is required for advisory GHSA-rjr6-rcgv-9m7m (Host/Origin
# checks). The transport is constructed stateless, so no in-memory session state.
gem 'mcp', '1.2.0'
# lib/tectonic/db.rb requires logger, which stopped being a default gem in Ruby
# 4.0. It was only reaching production as a transitive dependency of the test and
# development groups, which Render does not install.
gem 'logger'
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
  gem 'rubocop-minitest'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'rubocop-sequel'
end

group :test do
  gem 'capybara-selenium'
  gem 'minitest'
  gem 'minitest-capybara'
  gem 'rack-test'
end

