# frozen_string_literal: true

require_relative 'spec_helper'

# The public example page: a real block, planned against lifted, without an account. #693.
describe 'the example block' do
  include Rack::Test::Methods

  def app = Tectonic.app

  it 'is readable without signing in' do
    get '/example'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Four weeks, planned and lifted'
  end

  it 'shows plan against what was lifted, including what did not go to plan' do
    get '/example'
    body = last_response.body

    assert_includes body, '4 × 5 at 80% (100), RPE 8'
    assert_includes body, '100 × 5 @ 7, 100 × 5 @ 8, 100 × 5 @ 8, 100 × 5 @ 8'
    assert_includes body, '2 sets not done'
    assert_includes body, 'Skipped.'
  end

  # It can only stay a snapshot if nothing on it is read from an account.
  it 'reads no account to draw it' do
    queries = []
    logger = Object.new
    logger.define_singleton_method(:info) { |line| queries << line }
    %i[debug warn error].each { |level| logger.define_singleton_method(level) { |*| nil } }
    DB.loggers << logger
    get '/example'
    DB.loggers.delete(logger)

    assert_empty(queries.grep(/accounts|workouts|sets|programs/))
  end
end

describe 'the example block, found' do
  include Rack::Test::Methods

  def app = Tectonic.app

  def asset(name) = File.read(File.expand_path("../assets/#{name}", __dir__))

  it 'is linked from the front page and the connector docs, and offered to crawlers' do
    get '/welcome'
    assert_includes last_response.body, 'href="/example"'
    get '/docs'
    assert_includes last_response.body, 'href="/example"'

    assert_includes asset('sitemap.xml'), '<loc>https://tectonicplates.app/example</loc>'
    assert_includes asset('robots.txt'), "Allow: /example\n"
  end
end

