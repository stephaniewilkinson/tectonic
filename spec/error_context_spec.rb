# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/error_reporting'

# What an error report carries besides the backtrace. #385.
#
# The string `Sentry` appeared in exactly one file in this repository: config.ru. The whole
# integration was `Sentry.init` plus the Rack middleware, which is the default install and
# nothing beyond it. That gets exceptions with backtraces, which is the important half; what
# it does not get is any way to tell one error apart from another once they arrive.
#
# No user, so "users affected" read zero on every issue and an error seen 400 times was
# indistinguishable from one seen 400 times by a single lifter with a stuck client. No tags,
# so the web app and the MCP endpoint -- which share a Sentry project through the same URLMap,
# deliberately -- were one haystack. No contexts, so a failure inside the generator arrived
# with no record of which programme it was writing.
#
# The suite has no DSN, so every hook here is a no-op. What is asserted is the part that has
# to be right whether or not anything is listening: the route tag's shape, and that none of
# these can turn a working request into a failing one.
describe 'the route tag' do
  # A tag is what Sentry filters and groups on, and `route: request.path` -- which is what
  # #385 suggests -- would make it useless. /workouts/43689/session is a distinct value per
  # session, so a month of traffic is thousands of tags with one event each. The question
  # worth being able to ask is "every failure on the session screen".
  it 'takes the ids out, so a tag groups instead of counting to one' do
    assert_equal '/workouts/:id/session', Tectonic::ErrorReporting.route_tag('/workouts/43689/session')
  end

  it 'takes every id out, not only the first' do
    assert_equal '/workouts/:id/sets/:id/complete',
                 Tectonic::ErrorReporting.route_tag('/workouts/43689/sets/98765/complete')
  end

  # The words in a path are the app's own vocabulary rather than anybody's data, so they stay.
  # A tag of '/:id/:id/:id' would group everything into one bucket, which is the same failure
  # as grouping nothing.
  it 'leaves the words alone' do
    assert_equal '/programs/:id', Tectonic::ErrorReporting.route_tag('/programs/12')
    assert_equal '/exercises/new', Tectonic::ErrorReporting.route_tag('/exercises/new')
    assert_equal '/', Tectonic::ErrorReporting.route_tag('/')
  end

  # An id is a whole segment of digits. A movement named "5x5" is not an id, and a tag that
  # swallowed it would lose the one word that said which page this was.
  it 'only replaces a segment that is entirely digits' do
    assert_equal '/exercises/5x5', Tectonic::ErrorReporting.route_tag('/exercises/5x5')
    assert_equal '/workouts/2026-09-12', Tectonic::ErrorReporting.route_tag('/workouts/2026-09-12')
  end
end

# Every hook is a no-op where there is nothing to report to, which is every local run and the
# whole suite -- and the no-op path is the one that must never raise, because it runs on every
# single request.
describe 'the hooks with reporting switched off' do
  it 'is off in the suite' do
    refute Tectonic::ErrorReporting.on?
  end

  it 'describes a request without raising' do
    Tectonic::ErrorReporting.describe_request(path: '/workouts/1/session', account_id: 42)
  end

  it 'describes a request from nobody without raising' do
    Tectonic::ErrorReporting.describe_request(path: '/login', account_id: nil)
  end

  it 'notes a context without raising' do
    Tectonic::ErrorReporting.note('program', program_id: 1, week: 2)
  end
end

# The hook runs on every request through the Roda tree, including the ones that never reach an
# account. A request is the thing that must survive it: enrichment that raised would turn a
# page that was going to work into a 500.
describe 'a request with the hook in the tree' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'serves a page to somebody logged in' do
    login
    get '/workouts'

    assert_equal 200, last_response.status
  end

  it 'serves a page to nobody at all' do
    get '/welcome'

    assert_equal 200, last_response.status
  end

  # Before r.assets and r.public in the tree, so a failure serving one is described too.
  it 'serves an asset' do
    get '/assets/css/styles.css'

    assert_equal 200, last_response.status
  end
end

