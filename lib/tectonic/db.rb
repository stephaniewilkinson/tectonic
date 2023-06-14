# frozen_string_literal: true

require 'sequel'
require 'logger'

DB = Sequel.connect ENV.fetch 'DATABASE_URL'

DB.loggers << Logger.new($stdout)
