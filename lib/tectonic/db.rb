# frozen_string_literal: true

require 'sequel'
require 'logger'
# Every model reopens class Tectonic < Roda, so loading one outside app.rb -- from
# a rake task, say -- needs the superclass to already exist.
require 'roda'

DB = Sequel.connect ENV.fetch 'DATABASE_URL'
DB.extension :date_arithmetic
# pg_json backs the mcp_audit_log.arguments jsonb column and pg_array backs the
# api_tokens.scopes text[] column, so both come back as Ruby Hash/Array and can be
# written with Sequel.pg_jsonb / Sequel.pg_array.
DB.extension :pg_json, :pg_array

# Hide sequel's logging unless we're in test mode
DB.loggers << Logger.new($stdout) unless ENV['RACK_ENV'] == 'test'

