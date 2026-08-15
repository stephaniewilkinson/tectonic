# frozen_string_literal: true

require 'sequel'
require 'logger'
# Every model reopens class Tectonic < Roda, so loading one outside app.rb -- from
# a rake task, say -- needs the superclass to already exist.
require 'roda'

DB = Sequel.connect ENV.fetch 'DATABASE_URL'
DB.extension :date_arithmetic

# Hide sequel's logging unless we're in test mode
DB.loggers << Logger.new($stdout) unless ENV['RACK_ENV'] == 'test'

