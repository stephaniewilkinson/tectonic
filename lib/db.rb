# frozen_string_literal: true

require 'sequel'
require 'logger'

# Delete DATABASE_URL from the environment, so it isn't accidently
# passed to subprocesses.  DATABASE_URL may contain passwords.
DB = Sequel.connect ENV.fetch'DATABASE_URL' # for some reason this doesn't work until i switch it to .fetch

DB.loggers << Logger.new($stdout)
