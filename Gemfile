# frozen_string_literal: true

source 'https://rubygems.org'

ruby File.read(File.join(__dir__, '.ruby-version')).chomp.delete_prefix('ruby-')

gem 'bcrypt'
gem 'chartkick'
gem 'dotenv'
gem 'erubi'
gem 'http'
# Signs and verifies the OAuth JWT access tokens (rodauth-oauth's oauth_jwt feature
# depends on it; the MCP resource server also verifies tokens with it directly).
gem 'jwt'
# Pinned exactly: this gem is pre-1.0-ish and its API shifts between minor
# releases. >= 0.23.0 is required for advisory GHSA-rjr6-rcgv-9m7m (Host/Origin
# checks). The transport is constructed stateless, so no in-memory session state.
gem 'mcp', '1.2.0'
# lib/tectonic/db.rb requires logger, which stopped being a default gem in Ruby
# 4.0. It was only reaching production as a transitive dependency of the test and
# development groups, which Render does not install.
# Not used to send anything: every email this app sends goes through Resend's HTTP API in
# lib/tectonic/mailer.rb. Rodauth's email_base feature does an unconditional `require 'mail'`
# in post_configure, so enabling :reset_password without this gem fails at boot rather than
# at send time -- which is a strange way to discover a missing dependency, hence the note.
gem 'logger'
gem 'mail'
gem 'puma'
gem 'rack'
# Caps how long a request may occupy a thread. Required in config.ru rather than here,
# since nothing in this app calls Bundler.require.
gem 'rack-timeout'
gem 'rackup'
gem 'rake'
gem 'roda'
gem 'roda-http-auth'
gem 'rodauth'
# The OAuth 2.1 authorization server: authorization-code + PKCE, dynamic client
# registration, AS metadata, resource indicators (audience), token introspection,
# client-credentials, and JWT access tokens -- all as Rodauth features, so all auth
# runs through one framework rather than a hand-rolled server.
gem 'rodauth-oauth'
gem 'sentry-ruby'
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

