# frozen_string_literal: true

require_relative 'spec_helper'
require 'uri'

# Where the suite is pointed matters more than most configuration does, because it
# writes accounts, workouts, grants and audit rows and cleans none of them up. It used
# to inherit whatever database the app had been pointed at, which is how a bare
# `rake test` came to seed the development one.
describe 'the database the suite runs against' do
  it 'is never the development or production one, whatever DATABASE_URL held' do
    database = DB.opts[:database].to_s

    refute_includes database, 'development'
    refute_includes database, 'production'
  end

  it 'is the one TEST_DATABASE_URL names, so concurrent runs can have one each' do
    named = ENV.fetch('TEST_DATABASE_URL', nil)
    skip 'this run did not ask for a database of its own' unless named

    assert_equal URI.parse(named).path.delete_prefix('/'), DB.opts[:database].to_s
  end
end
