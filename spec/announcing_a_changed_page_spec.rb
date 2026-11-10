# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/index_now'
require 'open3'

# Telling IndexNow that the public pages may have changed. #692.
module IndexNowStubs
  Answer = Struct.new(:status, :body)
  Status = Struct.new(:code)

  # Stands in for the http gem's chain, so nothing leaves this machine: records what would have
  # been posted and answers with the given status, or raises the given error.
  class FakeClient
    attr_reader :posted

    def initialize(code: nil, error: nil)
      @code = code
      @error = error
    end

    def timeout(_seconds) = self

    def post(url, json:)
      raise @error if @error

      @posted = [url, json]
      Answer.new(Status.new(@code), 'nope')
    end
  end

  def ping_with(client, urls = ['https://tectonicplates.app/docs'])
    HTTP.stub(:timeout, ->(seconds) { client.timeout(seconds) }) { Tectonic::IndexNow.ping(urls) }
  end
end

describe 'the IndexNow key file' do
  include Rack::Test::Methods

  def app = Tectonic.app

  it 'is served at the address the submissions name, holding the key and nothing else' do
    get "/#{Tectonic::IndexNow::KEY}.txt"

    assert_equal 200, last_response.status
    assert_equal Tectonic::IndexNow::KEY, last_response.body
  end
end

describe 'announcing the public pages' do
  include IndexNowStubs

  it 'announces every page the sitemap lists, and only those' do
    sitemap = File.read(Tectonic::IndexNow::SITEMAP)

    assert_equal sitemap.scan('<loc>').size, Tectonic::IndexNow.urls.size
    assert_includes Tectonic::IndexNow.urls, 'https://tectonicplates.app/docs'
  end

  it 'posts the host, the key, where the key lives and the pages' do
    client = IndexNowStubs::FakeClient.new(code: 202)
    message = ping_with(client)

    url, body = client.posted
    assert_equal 'https://api.indexnow.org/indexnow', url
    assert_equal({ host: 'tectonicplates.app', key: Tectonic::IndexNow::KEY,
                   keyLocation: "https://tectonicplates.app/#{Tectonic::IndexNow::KEY}.txt",
                   urlList: ['https://tectonicplates.app/docs'] }, body)
    assert_match(/accepted 1 URL\(s\): 202/, message)
  end

  it 'says a refusal rather than raising' do
    assert_match(/refused 1 URL\(s\): 403/, ping_with(IndexNowStubs::FakeClient.new(code: 403)))
  end

  it 'says an unreachable engine rather than raising' do
    message = ping_with(IndexNowStubs::FakeClient.new(error: HTTP::ConnectionError.new('down')))

    assert_match(/could not be reached: HTTP::ConnectionError/, message)
  end
end


# The order production boots in: config.ru freezes the app, and only then does Puma's
# after_booted hook require the module that does the announcing. The first deploy of #692
# raised FrozenError there, a minute after boot, because the module was first defined inside
# the already-frozen class. A fresh process, because this one loaded the module long ago.
describe 'announcing from a frozen app' do
  it 'finds the module already loaded, so requiring it after the freeze changes nothing' do
    root = File.expand_path('..', __dir__)
    script = "require './app'; Tectonic.freeze; require './lib/tectonic/index_now'; print Tectonic::IndexNow::HOST"
    output, status = Open3.capture2e({ 'RACK_ENV' => 'test' }, 'bundle', 'exec', 'ruby', '-e', script, chdir: root)

    assert_predicate status, :success?, output
    assert_equal 'tectonicplates.app', output.lines.last
  end
end
