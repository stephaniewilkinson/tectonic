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

describe 'the CI workflow' do
  # The suite runs as two jobs, so a browser discarded under the driver fails only the
  # job that drives one. The Rakefile cuts both halves from a single glob, so no spec file
  # can fall between them -- but a workflow that stopped naming a half would quietly drop
  # that half whole, and a green build is exactly what that looks like.
  it 'runs both halves of the suite' do
    workflow = File.read(File.expand_path('../.github/workflows/ruby.yml', __dir__))

    assert_includes workflow, 'rake test:rack'
    assert_includes workflow, 'rake test:browser'
  end
end

describe 'the Capybara server' do
  # Capybara takes a free port when none is named. Naming one is what made a second
  # suite collide with the first, and app_host repeated the number, so fixing either
  # without the other would have sent the browser to a server that was not there.
  it 'is left to find its own port rather than pinned to one' do
    assert_nil Capybara.server_port
    assert_nil Capybara.app_host
  end
end

