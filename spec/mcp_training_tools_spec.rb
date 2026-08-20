# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'

NamedClient = Struct.new(:id, :account_id)

# A registered OAuth client with a given name plus an account, so provenance can be
# checked reading the client's name back off the row it stamped.
def named_client(name)
  account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  application = Tectonic::OAuthApplication.create(name:, client_id: SecureRandom.uuid,
                                                  client_secret: SecureRandom.hex,
                                                  redirect_uri: 'https://e/cb', scopes: 'read')
  NamedClient.new(application.id, account_id)
end

describe 'create_exercise' do
  include Rack::Test::Methods

  it 'creates once and returns the same row for a duplicate name' do
    raw = mint(scopes: ['write']).raw
    name = "Move #{SecureRandom.hex(4)}"
    call_tool('create_exercise', raw:, arguments: { name: })
    first = tool_result['structuredContent']['id']
    call_tool('create_exercise', raw:, arguments: { name: })
    assert_equal first, tool_result['structuredContent']['id']
  end
end

describe 'create_workout' do
  include Rack::Test::Methods

  it 'reuses the workout for a given day' do
    raw = mint(scopes: ['write']).raw
    call_tool('create_workout', raw:, arguments: { date: '2027-03-04' })
    first = tool_result['structuredContent']['id']
    call_tool('create_workout', raw:, arguments: { date: '2027-03-04' })
    assert_equal first, tool_result['structuredContent']['id']
  end
end

describe 'create_set stamping' do
  include Rack::Test::Methods

  it 'creates the exercise + workout and stamps the set with the token' do
    token = mint(scopes: ['write'])
    call_tool('create_set', raw: token.raw,
                            arguments: { exercise: 'Back Squat', date: 'today', weight: 135, reps: 5 })
    set = Tectonic::Set[tool_result['structuredContent']['id']]
    assert_equal token.application_id, set.created_by_oauth_application_id
  end
end

describe 'create_set validation' do
  include Rack::Test::Methods

  it 'refuses a weight outside the allowed range' do
    raw = mint(scopes: ['write']).raw
    call_tool('create_set', raw:, arguments: { exercise: 'Back Squat', weight: 99_999, reps: 5 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'out of range'
  end
end

describe 'list_exercises isolation' do
  include Rack::Test::Methods

  it "never shows another account's private exercise" do
    secret = "Secret #{SecureRandom.hex(4)}"
    call_tool('create_exercise', raw: mint(scopes: ['write']).raw, arguments: { name: secret })
    call_tool('list_exercises', raw: mint(scopes: ['read']).raw)
    names = tool_result['structuredContent']['exercises'].map { |e| e['name'] }
    refute_includes names, secret
  end
end

describe 'create_set isolation' do
  include Rack::Test::Methods

  it "never lands a set on another account's workout" do
    call_tool('create_workout', raw: mint(scopes: ['write']).raw, arguments: { date: '2027-05-05' })
    other_workout = tool_result['structuredContent']['id']
    call_tool('create_set', raw: mint(scopes: ['write']).raw,
                            arguments: { exercise: 'Back Squat', date: '2027-05-05', weight: 135, reps: 5 })
    set = Tectonic::Set[tool_result['structuredContent']['id']]
    refute_equal other_workout, set.workout_id
  end
end

describe 'the provenance helper' do
  let(:app) { Tectonic.new({}) }

  it 'names the client and date for an LLM-made row, nil for a human one' do
    client = named_client('Claude Desktop')
    made = Tectonic::Exercise.create(name: "P#{SecureRandom.hex(4)}", account_id: client.account_id,
                                     created_by_oauth_application_id: client.id, created_at: Time.now)
    human = Tectonic::Exercise.create(name: "P#{SecureRandom.hex(4)}", account_id: client.account_id)
    assert_includes app.provenance(made), 'Created by Claude Desktop on'
    assert_nil app.provenance(human)
  end
end

describe 'search and fetch' do
  include Rack::Test::Methods

  it 'finds a created exercise and fetches its detail back' do
    account = new_account
    raw = mint(scopes: %w[read write], account_id: account).raw
    name = "Findable #{SecureRandom.hex(4)}"
    call_tool('create_exercise', raw:, arguments: { name: })
    call_tool('search', raw:, arguments: { query: name })
    hit = tool_result['structuredContent']['results'].find { |r| r['title'] == name }
    assert_match(/\Aexercise:\d+\z/, hit['id'])
    call_tool('fetch', raw:, arguments: { id: hit['id'] })
    document = tool_result['structuredContent']
    assert_equal name, document['title']
    assert document['text'] && document['url']
  end

  it "never fetches another account's object" do
    call_tool('create_exercise', raw: mint(scopes: ['write']).raw, arguments: { name: "S#{SecureRandom.hex(4)}" })
    handle = "exercise:#{tool_result['structuredContent']['id']}"
    call_tool('fetch', raw: mint(scopes: ['read']).raw, arguments: { id: handle })
    assert tool_result['isError']
  end
end

