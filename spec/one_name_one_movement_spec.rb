# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/exercise_names'
require 'securerandom'

# One name, one movement. #474 and #478.
#
# The reporting account holds five duplicate pairs. None was made by an assistant -- the audit
# log shows 27 movements created over MCP and not one repeated name -- and all five are the
# shared library landing on top of training that was already there:
#
#     Benchpress [5] / Bench Press [8]        Deadlift [2] / Deadlift [9]
#     Overhead press [3] / Overhead Press [44]  Squat [1] / Back Squat [7]
#     Bent over row [4] / Bent Over Row [48]
#
# Two different failures made them, and they need two different answers.
#
# **Same name, written differently.** `Benchpress` and `Bench Press` are one movement, and an
# exact string match cannot see it. Folding settles this, and the app can settle it alone.
#
# **Different name, same movement.** `Squat` is not `Back Squat` by any spelling rule. Fifteen
# movements on that account have "squat" in the name and none folds to `squat`, so nothing
# catches a sixteenth. Only the lifter knows, so the app asks.
module OneName
  def a_movement(account_id, name)
    Tectonic::Exercise.create(account_id:, name:, is_barbell: false)
  end

  def scratch = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

# The spelling half, settled without asking anybody.
describe 'what counts as the same name' do
  include OneName

  it 'ignores case and punctuation and spacing' do
    ['Benchpress', 'bench press', 'BENCH-PRESS'].each do |spelling|
      assert_equal Tectonic::ExerciseNames.fold('Bench Press'), Tectonic::ExerciseNames.fold(spelling)
    end
  end

  it 'keeps genuinely different names apart' do
    refute_equal Tectonic::ExerciseNames.fold('Bench Press'), Tectonic::ExerciseNames.fold('Overhead Press')
  end
end

describe 'finding the movement an account means by a name' do
  include OneName

  before { @account_id = scratch }

  it 'finds one written a different way' do
    mine = a_movement(@account_id, 'Bench Press')

    assert_equal mine.id, Tectonic::Exercise.matching(@account_id, 'benchpress').id
  end

  # The part that was decided by accident. Both rows are visible, so a name can match two --
  # and this account's private Deadlift carries 64 sets, a training max and seven program
  # lifts while the library's carries nothing. Ordering by id picked the right one only
  # because it happened to be older.
  # Against a real library row rather than one made here. The cleaner between tests keeps
  # `account_id IS NULL` rows on purpose -- the library is not test data, it is what
  # `rake library:exercises` installs -- so a spec that creates one leaves it behind for every
  # test afterwards. Two of these did, and the isolation spec caught it.
  it 'prefers the account own row over the library one' do
    mine = a_movement(@account_id, 'Deadlift')

    assert_equal mine.id, Tectonic::Exercise.matching(@account_id, 'Deadlift').id
    refute_nil Tectonic::Exercise.first(account_id: nil, name: 'Deadlift'), 'wanted a library row to lose'
  end

  it 'still finds a library movement where the account has none of its own' do
    found = Tectonic::Exercise.matching(@account_id, 'Deadlift')

    assert found.library?
  end

  it 'does not reach into another account' do
    theirs = a_movement(scratch, "Zercher #{SecureRandom.hex(4)}")

    assert_nil Tectonic::Exercise.matching(@account_id, theirs.name)
  end
end

# The nearness half, which is never decided here -- it only produces the candidates.
describe 'which movements a new name might already be' do
  include OneName

  def near?(one, other) = Tectonic::ExerciseNames.near?(one, other)

  it 'offers a movement whose name contains this one' do
    assert near?('Squat', 'Back Squat')
    assert near?('Squat', 'Bulgarian Split Squat')
    assert near?('Bench Press', 'Incline Dumbbell Bench Press')
  end

  # The reason this is subset rather than any-shared-word. Both of these are banded and they
  # are not the same movement, and a prompt that is usually wrong is one people learn to
  # dismiss without reading.
  it 'does not offer one that merely shares a word' do
    refute near?('Band Face Pull', 'Band Tricep Pushdown')
    refute near?('Overhead Press', 'Bench Press')
  end

  it 'does not match across a word boundary that is not there' do
    refute near?('Dead Bug', 'Deadlift')
  end

  # Anything folding to the same name is matching's answer, not a question, so it is kept out
  # of the candidates: a caller who typed "Benchpress" is told the movement exists rather than
  # asked whether they meant it.
  it 'leaves out the ones that are simply the same name' do
    account_id = scratch
    a_movement(account_id, 'Bench Press')

    assert_empty Tectonic::Exercise.similar_to(account_id, 'benchpress')
  end
end

# Over MCP, where there is nobody to ask, so it refuses in a way a model can act on.
describe 'writing against a name the account may already have' do
  include Rack::Test::Methods
  include OneName

  before do
    @token = mint(scopes: %w[read write])
    @squat = a_movement(@token.account_id, "Back Squat #{SecureRandom.hex(4)}")
  end

  def make(name, **extra)
    call_tool('create_exercise', raw: @token.raw, arguments: { name:, **extra })
  end

  def said = tool_result.dig('content', 0, 'text')

  it 'refuses rather than opening a second row' do
    make('Squat')

    assert tool_result['isError']
    assert_includes said, @squat.name
  end

  it 'says what to do about it, and creates nothing meanwhile' do
    make('Squat')

    assert_includes said, 'new_exercise: true'
    assert_nil Tectonic::Exercise.matching(@token.account_id, 'Squat')
  end

  # The door that can say yes, and the only one. Every other tool refuses and points here.
  it 'goes ahead once the caller says it is a different movement' do
    make('Squat', new_exercise: true)

    refute tool_result['isError']
    refute_nil Tectonic::Exercise.matching(@token.account_id, 'Squat')
  end
end

# What must go on working, which is most of what this tool does: every accessory an assistant
# has ever added arrived through a name with nothing like it, and a check that asked about
# those would be unusable.
describe 'writing against a name that is plainly new' do
  include Rack::Test::Methods
  include OneName

  before do
    @token = mint(scopes: %w[read write])
    @squat = a_movement(@token.account_id, "Back Squat #{SecureRandom.hex(4)}")
  end

  def make(name, **extra)
    call_tool('create_exercise', raw: @token.raw, arguments: { name:, **extra })
  end

  it 'asks nothing at all' do
    make("Copenhagen Plank #{SecureRandom.hex(4)}")

    refute tool_result['isError']
  end

  # And the folding half through the same door: an existing movement is handed back rather
  # than duplicated, with no question asked either.
  it 'hands back the movement that is simply this one spelled differently' do
    make(@squat.name.downcase.delete(' '))

    refute tool_result['isError']
    assert_equal @squat.id, tool_result['structuredContent']['id']
  end
end

# The other tools reach the same resolver, and they are the ones that were actually scattering
# training: a block written against a slightly-off name used to open a row and fill it.
describe 'writing a set against a name the account may already have' do
  include Rack::Test::Methods
  include OneName

  it 'refuses and points at create_exercise' do
    token = mint(scopes: %w[read write])
    a_movement(token.account_id, "Back Squat #{SecureRandom.hex(4)}")

    call_tool('create_set', raw: token.raw,
                            arguments: { exercise: 'Squat', weight: 155, reps: 5 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'create_exercise'
  end
end

# And in the browser, where there is a person to ask, so it is a step rather than an error.
describe 'adding a movement whose name might already be here' do
  include Rack::Test::Methods
  include RouteOwnership
  include OneName

  before do
    @account_id = login
    @squat = a_movement(@account_id, "Back Squat #{SecureRandom.hex(4)}")
  end

  def add(name, **extra)
    post '/exercises', { 'id' => '', 'name' => name, 'note' => 'Knees out',
                         '_csrf' => token_for('/exercises/new'), **extra }
  end

  it 'asks instead of saving' do
    add('Squat')

    assert_includes last_response.body, @squat.name
    assert_nil Tectonic::Exercise.matching(@account_id, 'Squat')
  end

  # A question that costs what you typed is a question people learn to dodge, so the confirm
  # button carries the fields back and the form keeps its values.
  it 'keeps what was typed while it asks' do
    add('Squat')

    assert_includes last_response.body, 'Knees out'
    assert_includes last_response.body, 'name="new_exercise"'
  end
end

# Confirming keeps everything that was typed, which is the other half of asking politely.
describe 'confirming that it really is a different movement' do
  include Rack::Test::Methods
  include RouteOwnership
  include OneName

  it 'saves it, note and all' do
    account_id = login
    a_movement(account_id, "Back Squat #{SecureRandom.hex(4)}")

    post '/exercises', { 'id' => '', 'name' => 'Squat', 'note' => 'Knees out',
                         'new_exercise' => '1', '_csrf' => token_for('/exercises/new') }

    movement = Tectonic::Exercise.matching(account_id, 'Squat')
    refute_nil movement
    assert_equal 'Knees out', movement.note
  end
end

describe 'adding a movement whose name is plainly its own' do
  include Rack::Test::Methods
  include RouteOwnership
  include OneName

  before do
    @account_id = login
    @squat = a_movement(@account_id, "Back Squat #{SecureRandom.hex(4)}")
  end

  def add(name, **extra)
    post '/exercises', { 'id' => '', 'name' => name, 'note' => 'Knees out',
                         '_csrf' => token_for('/exercises/new'), **extra }
  end

  # Folding first: the same movement spelled differently is not a question, it is an answer.
  it 'goes straight to the movement this name already is' do
    add(@squat.name.downcase.delete(' '))

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], "/exercises/#{@squat.id}/"
  end

  it 'does not ask about a movement with nothing like it' do
    add("Copenhagen Plank #{SecureRandom.hex(4)}")

    assert_equal 302, last_response.status
  end
end

# The loader that actually made all five duplicates. #477.
#
# `load_library` asks whether a name exists *as a library row* and never looks at private
# rows, and it runs on every deploy. When the library gained Bench Press, Overhead Press,
# Bent Over Row, Deadlift and Back Squat, five collisions appeared at once against training
# going back to 2023, and nothing said so.
#
# It cannot be prevented here, which is worth pinning rather than just asserting: a library
# row is global, so skipping the insert because one account holds a private row of that name
# would deny the movement to every other account. The loader acts on a global fact and the
# collision is a per-account one.
describe 'adding a library movement an account already has its own of' do
  include OneName

  it 'names the accounts it collided with' do
    account_id = scratch
    a_movement(account_id, 'Bench press')

    collisions = Tectonic::Exercise.library_collisions(['Bench Press'])

    assert_equal [account_id], collisions['Bench Press']
  end

  # Folded, so it catches the spelling differences that produced the real ones -- the account
  # row was "Benchpress" and the library's is "Bench Press".
  it 'sees a collision through a difference in spelling' do
    account_id = scratch
    a_movement(account_id, 'Benchpress')

    assert_includes Tectonic::Exercise.library_collisions(['Bench Press']).fetch('Bench Press', []), account_id
  end

  it 'says nothing about a name nobody has their own of' do
    assert_empty Tectonic::Exercise.library_collisions(["Jefferson Curl #{SecureRandom.hex(4)}"])
  end

  it 'says nothing when no names were added at all' do
    assert_empty Tectonic::Exercise.library_collisions([])
  end
end

