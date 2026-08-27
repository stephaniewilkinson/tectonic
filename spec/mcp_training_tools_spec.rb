# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/exercise_library' # Exercise.load_library, for the shared-library specs
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

# A movement from the shared library: nil account, so every account sees it and none
# owns it. Taken from the seeded library rather than made here, and the library is
# seeded first so this file can be run on its own. Inventing a nil-account row instead
# would leave one behind -- a null account_id is the one thing the teardown in
# spec_helper keeps -- and the library is counted by name elsewhere, so a spare would
# fail a spec in another file rather than in this one.
def shared_exercise
  Tectonic::Exercise.load_library
  Tectonic::Exercise.where(account_id: nil).order(:id).first
end

# An account's own movement, made through the tool so provenance and ownership are
# stamped the way a real call would stamp them.
def own_exercise(token)
  call_tool('create_exercise', raw: token.raw, arguments: { name: "Cue #{SecureRandom.hex(4)}" })
  tool_result['structuredContent']['id']
end

describe 'create_exercise with a note' do
  include Rack::Test::Methods

  it 'stores the coaching intent it was given on a movement it creates' do
    call_tool('create_exercise', raw: mint(scopes: ['write']).raw,
                                 arguments: { name: "Cue #{SecureRandom.hex(4)}",
                                              note: 'this helps correct valgus' })

    assert_equal 'this helps correct valgus', tool_result['structuredContent']['note']
  end

  # This tool deduplicates against the library as well as the account's own movements,
  # so a note aimed at a shared name comes back holding the row every account reads.
  # Refusing beats reporting a success that stored nothing, and beats storing it.
  it 'refuses rather than noting a movement from the shared library' do
    shared = shared_exercise
    call_tool('create_exercise', raw: mint(scopes: ['write']).raw,
                                 arguments: { name: shared.name, note: 'mine alone' })

    assert tool_result['isError']
    assert_nil shared.refresh.note
  end
end

describe 'update_exercise' do
  include Rack::Test::Methods

  before { @token = mint(scopes: ['write']) }

  it 'writes a note onto a movement the account owns' do
    id = own_exercise(@token)
    call_tool('update_exercise', raw: @token.raw, arguments: { exercise_id: id, note: 'ribs down' })

    assert_equal 'ribs down', Tectonic::Exercise[id].note
    assert_includes tool_result.dig('content', 0, 'text'), 'ribs down'
  end

  # A field the caller did not send is a field the caller did not mean to touch, or
  # every rename would quietly take the note with it.
  it 'leaves the note alone when the edit does not mention it' do
    id = own_exercise(@token)
    call_tool('update_exercise', raw: @token.raw, arguments: { exercise_id: id, note: 'ribs down' })
    call_tool('update_exercise', raw: @token.raw, arguments: { exercise_id: id, name: 'Renamed cue' })

    assert_equal 'ribs down', Tectonic::Exercise[id].note
  end

  it 'clears the note when sent an empty string' do
    id = own_exercise(@token)
    call_tool('update_exercise', raw: @token.raw, arguments: { exercise_id: id, note: 'ribs down' })
    call_tool('update_exercise', raw: @token.raw, arguments: { exercise_id: id, note: '' })

    assert_nil Tectonic::Exercise[id].note
  end
end

# The same ownership rule the exercise form follows, reached the other way in. No
# account may write a value another account reads, and the library is the whole of the
# difference between what an account can see and what it owns.
describe 'update_exercise ownership' do
  include Rack::Test::Methods

  it 'refuses a library movement and says that is why, not that the id was wrong' do
    shared = shared_exercise
    call_tool('update_exercise', raw: mint(scopes: ['write']).raw,
                                 arguments: { exercise_id: shared.id, note: 'mine alone' })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'shared library'
    assert_nil shared.refresh.note
  end

  it "refuses another account's private movement" do
    theirs = own_exercise(mint(scopes: ['write']))
    call_tool('update_exercise', raw: mint(scopes: ['write']).raw,
                                 arguments: { exercise_id: theirs, note: 'mine alone' })

    assert tool_result['isError']
    assert_nil Tectonic::Exercise[theirs].note
  end

  # Auditing comes from the tool base class rather than from the tool, so what this
  # really asserts is that the tool is registered and declared a write: one that had
  # declared a read would land no row here, and would take a read-only token's edit.
  it 'lands an audit row the way every other write tool does' do
    token = mint(scopes: ['write'])
    call_tool('update_exercise', raw: token.raw, arguments: { exercise_id: own_exercise(token), note: 'cue' })
    row = Tectonic::McpAuditLog.where(oauth_application_id: token.application_id, tool_name: 'update_exercise')

    assert_equal 'success', row.get(:result_status)
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
    set = Tectonic::WorkoutSet[tool_result['structuredContent']['id']]
    assert_equal token.application_id, set.created_by_oauth_application_id
  end
end

# A set an assistant logs has to arrive knowing whether it is on a bar, or it renders
# without the plate breakdown that is the point of the app. Nothing asks the model:
# the flag is read off the movement the set landed on, here a private row the resolver
# created from the name, which is recognised as a barbell lift by that name alone.
describe 'create_set plate math' do
  include Rack::Test::Methods

  it 'takes the barbell flag from the movement rather than from the caller' do
    raw = mint(scopes: ['write']).raw
    call_tool('create_set', raw:, arguments: { exercise: 'Back Squat', weight: 135, reps: 5 })
    assert Tectonic::WorkoutSet[tool_result['structuredContent']['id']].is_barbell
    call_tool('create_set', raw:, arguments: { exercise: 'Cable Fly', weight: 40, reps: 12 })
    refute Tectonic::WorkoutSet[tool_result['structuredContent']['id']].is_barbell
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
    set = Tectonic::WorkoutSet[tool_result['structuredContent']['id']]
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

