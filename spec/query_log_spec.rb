# frozen_string_literal: true

require_relative 'spec_helper'
require 'English'

# Sequel writes every statement with its bound values, so an attached logger on a
# deployment ships email addresses and everybody's weights and reps to the host's log
# store. db.rb decides once, at require time, and this process required it as 'test' --
# so asking DB.loggers here can only describe the one environment the question does not
# matter for. Each case gets a fresh ruby that loads the file under the environment being
# tested and reports what it attached; loading db.rb alone costs a connection and nothing
# else, no app and no browser.
DB_FILE = File.expand_path '../lib/tectonic/db', __dir__

# DB_LOG is cleared unless a case sets it, so a shell that happens to carry one cannot
# turn the negative cases into passes.
def loggers_under(env)
  script = "require '#{DB_FILE}'; print DB.loggers.size"
  output = IO.popen({ 'DB_LOG' => nil }.merge(env), ['ruby', '-e', script], &:read)

  raise "db.rb would not load under #{env.inspect}" unless $CHILD_STATUS.success?

  Integer output.strip
end

describe 'the sequel query log' do
  it 'is off in production, where the statements would carry people\'s data' do
    assert_equal 0, loggers_under('RACK_ENV' => 'production')
  end

  it 'is off in staging too, which holds the same kind of rows' do
    assert_equal 0, loggers_under('RACK_ENV' => 'staging')
  end

  it 'is on in development, where reading the SQL is the point' do
    assert_equal 1, loggers_under('RACK_ENV' => 'development')
  end

  # The escape hatch: a deployment being traced, switched on for as long as it takes.
  it 'can be turned on anywhere by DB_LOG' do
    assert_equal 1, loggers_under('RACK_ENV' => 'production', 'DB_LOG' => '1')
  end

  # dotenv sets a name listed without a value to "", which is how a variable meant to be
  # off arrives set.
  it 'treats an empty DB_LOG as unset' do
    assert_equal 0, loggers_under('RACK_ENV' => 'production', 'DB_LOG' => '')
  end
end

