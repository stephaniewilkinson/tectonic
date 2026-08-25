# frozen_string_literal: true

require 'sequel'
require 'logger'
# Every model reopens class Tectonic < Roda, so loading one outside app.rb -- from
# a rake task, say -- needs the superclass to already exist.
require 'roda'

# max_connections is Sequel's own default of four without this, one short of the five
# threads Puma serves requests on, so the fifth thread waited for a connection and could
# raise Sequel::PoolTimeout on a request that had nothing wrong with it. config/puma.rb
# sizes the thread pool from the same variable, so the two cannot drift apart again.
DB = Sequel.connect ENV.fetch('DATABASE_URL'), max_connections: Integer(ENV.fetch('RAILS_MAX_THREADS', 5))
DB.extension :date_arithmetic
# pg_json backs the mcp_audit_log.arguments jsonb column, so it comes back as a Ruby
# Hash and can be written with Sequel.pg_jsonb.
DB.extension :pg_json

# Hide sequel's logging unless we're in test mode
DB.loggers << Logger.new($stdout) unless ENV['RACK_ENV'] == 'test'

