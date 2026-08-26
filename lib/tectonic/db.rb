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

# Sequel logs each statement with its bound values, so a logger attached here writes out
# the email address on an accounts row and every weight and rep somebody has recorded.
# That is fine on your own machine, where the data is yours and reading the SQL is the
# point, and wrong on a deployment, where the lines go to a log store nobody chose to keep
# a training log in, are retained and billed by the host, and cost a formatted line per
# query on the request path. This read `unless RACK_ENV == 'test'` for years, which
# quietened the suite and left development and production both logging everything.
#
# DB_LOG turns the log on wherever it is set, which is what makes tracing a real query
# against a deployment possible for as long as it takes and no longer. Empty counts as
# unset, as it does everywhere else here, because a name listed in a .env without a value
# arrives as "".
DB.loggers << Logger.new($stdout) if ENV['RACK_ENV'] == 'development' || !ENV.fetch('DB_LOG', nil).to_s.empty?

