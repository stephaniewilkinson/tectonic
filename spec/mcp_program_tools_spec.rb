# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# One squat day in week one, written the way a model would send it.
def block_arguments(name, weeks: 1)
  { name:, block: 0, start_date: '2027-01-04', preferred_reps: 3,
    weeks: Array.new(weeks) do |index|
      { number: index + 1,
        days: [{ weekday: 1, focus: 'Squat',
                 lifts: [{ exercise: 'Back Squat', sets: 4, reps: 5, top_weight: 155, is_main: true },
                         { exercise: 'Barbell Row', sets: 3, reps: 8, top_weight: 95 }] }] }
    end }
end

def write_block(raw, weeks: 1)
  call_tool('create_program', raw:, arguments: block_arguments("Block #{SecureRandom.hex(4)}", weeks:))
  tool_result['structuredContent']
end

describe 'create_program' do
  include Rack::Test::Methods

  it 'writes the block, its weeks, days and every lift in one call' do
    program = write_block(mint(scopes: %w[read write]).raw)
    day = program['weeks'].first['days'].first
    assert_equal 1, program['weeks'].length
    assert_equal '2027-01-04', day['date'] # weekday 1 of a block opening that Monday
    assert_equal(['Back Squat', 'Barbell Row'], day['lifts'].map { |lift| lift['exercise'] })
    assert_equal([0, 1], day['lifts'].map { |lift| lift['position'] })
  end

  it 'refuses a second block of the same name rather than quietly duplicating it' do
    raw = mint(scopes: ['write']).raw
    arguments = block_arguments("Block #{SecureRandom.hex(4)}")
    call_tool('create_program', raw:, arguments:)
    call_tool('create_program', raw:, arguments:)
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'already have a block'
  end
end

# Pricing is validated before anything is written, so a bad lift leaves no block behind.
describe 'creating a program with a badly priced lift' do
  include Rack::Test::Methods

  it 'refuses a lift that is priced twice or not at all, and writes nothing' do
    raw = mint(scopes: %w[read write]).raw
    arguments = block_arguments("Block #{SecureRandom.hex(4)}")
    arguments[:weeks][0][:days][0][:lifts][0][:percent_of_max] = 80
    call_tool('create_program', raw:, arguments:)
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'exactly one of top_weight'
    call_tool('list_programs', raw:)
    assert_empty tool_result['structuredContent']['programs']
  end
end

describe 'reading a program back' do
  include Rack::Test::Methods

  it 'lists blocks with the week today falls in and fetches one in full' do
    raw = mint(scopes: %w[read write]).raw
    written = write_block(raw)
    call_tool('list_programs', raw:)
    listed = tool_result['structuredContent']['programs'].first
    assert_equal written['id'], listed['id']
    assert_equal 1, listed['weeks']
    call_tool('get_program', raw:, arguments: { program_id: written['id'] })
    assert_equal 2, tool_result['structuredContent']['weeks'].first['days'].first['lifts'].length
  end

  it 'finds a block by name through search and fetches it by handle' do
    raw = mint(scopes: %w[read write]).raw
    written = write_block(raw)
    call_tool('search', raw:, arguments: { query: written['name'] })
    hit = tool_result['structuredContent']['results'].find { |row| row['title'] == written['name'] }
    assert_equal "program:#{written['id']}", hit['id']
    call_tool('fetch', raw:, arguments: { id: hit['id'] })
    assert_equal 1, tool_result['structuredContent']['metadata']['weeks'].length
  end
end

describe 'editing a program' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @lifts = @program['weeks'].first['days'].first['lifts']
  end

  it 'changes a load and says exactly what moved' do
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: @lifts.first['id'], top_weight: 175 })
    changed = tool_result['structuredContent']['changed']
    assert_equal({ 'from' => 155, 'to' => 175 }, changed['top_weight'])
    assert_includes tool_result.dig('content', 0, 'text'), 'top_weight 155 to 175'
  end

  it 'substitutes the movement and takes its plate math with it' do
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: @lifts.last['id'], exercise: 'Cable Row' })
    lift = tool_result['structuredContent']
    assert_equal 'Cable Row', lift['exercise']
    refute lift['is_barbell'] # a cable row is not loaded on a bar, whatever it replaced
  end
end

# Position is what orders a day, so renumbering has to leave no two lifts sharing one.
describe 'reordering a day' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @lifts = @program['weeks'].first['days'].first['lifts']
  end

  it 'reorders a day by renumbering it, leaving no two lifts in the same place' do
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: @lifts.last['id'], position: 0 })
    call_tool('get_program', raw: @raw, arguments: { program_id: @program['id'] })
    lifts = tool_result['structuredContent']['weeks'].first['days'].first['lifts']
    assert_equal(['Barbell Row', 'Back Squat'], lifts.map { |lift| lift['exercise'] })
    assert_equal([0, 1], lifts.map { |lift| lift['position'] })
  end
end

# The two ways a lift can be priced are exclusive, so an edit has to be refused or
# swapped rather than left holding both.
describe 'repricing a lift' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @lifts = @program['weeks'].first['days'].first['lifts']
  end

  it 'refuses an edit that would leave a lift priced two ways' do
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: @lifts.first['id'], percent_of_max: 80 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'exactly one of top_weight'
  end

  it 'swaps pounds for a percentage when the other is nulled in the same call' do
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: @lifts.first['id'],
                                                  percent_of_max: 80, top_weight: nil })
    lift = tool_result['structuredContent']
    assert_nil lift['top_weight']
    assert_equal 80, lift['percent_of_max']
  end
end

# Adding and removing rather than editing in place: the positions have to close up
# behind a departure and open at the end for an arrival.
describe 'changing what a day contains' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @lifts = @program['weeks'].first['days'].first['lifts']
  end

  it 'removes a lift and closes the gap its position left' do
    call_tool('delete_program_lift', raw: @raw, arguments: { program_lift_id: @lifts.first['id'] })
    assert_equal 'Back Squat', tool_result['structuredContent']['removed']['exercise']
    call_tool('get_program', raw: @raw, arguments: { program_id: @program['id'] })
    lifts = tool_result['structuredContent']['weeks'].first['days'].first['lifts']
    assert_equal([['Barbell Row', 0]], lifts.map { |lift| [lift['exercise'], lift['position']] })
  end

  it 'adds a lift to the end of a day' do
    day = @program['weeks'].first['days'].first
    call_tool('add_program_lift', raw: @raw,
                                  arguments: { program_day_id: day['id'], exercise: 'Overhead Press',
                                               sets: 3, reps: 5, top_weight: 65 })
    assert_equal 2, tool_result['structuredContent']['position']
  end
end

# Moving the day itself rather than its contents, which re-dates the session it generates.
describe 'moving a training day' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @lifts = @program['weeks'].first['days'].first['lifts']
  end

  it 'moves a training day to another weekday, re-dating the session' do
    day = @program['weeks'].first['days'].first
    call_tool('update_program_day', raw: @raw, arguments: { program_day_id: day['id'], weekday: 3 })
    assert_equal '2027-01-06', tool_result['structuredContent']['date']
    assert_equal({ 'from' => 1, 'to' => 3 }, tool_result['structuredContent']['changed']['weekday'])
  end
end

describe 'extending a block' do
  include Rack::Test::Methods

  it "copies a week's days and lifts into a new one" do
    raw = mint(scopes: %w[read write]).raw
    program = write_block(raw)
    call_tool('add_program_week', raw:,
                                  arguments: { program_id: program['id'], copy_from_week: 1, is_deload: true })
    week = tool_result['structuredContent']
    assert_equal 2, week['number']
    assert week['is_deload']
    assert_equal '2027-01-11', week['start_date'] # seven days after week one
    assert_equal(['Back Squat', 'Barbell Row'], week['days'].first['lifts'].map { |lift| lift['exercise'] })
  end
end

describe 'generating a week from a program' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
  end

  it 'writes a session of warmups and working sets, and does nothing the second time' do
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 1 })
    workout = tool_result['structuredContent']['workouts'].first
    assert_equal '2027-01-04', workout['date']
    before = workout['sets']
    assert_operator before, :>, 4 # four working sets plus the ramp above the bar

    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 1 })
    again = tool_result['structuredContent']['workouts'].first
    assert_equal workout['id'], again['id']
    assert_equal before, again['sets']
  end

  it 'stamps the session with the client that asked for it' do
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 1 })
    workout = Tectonic::Workout[tool_result['structuredContent']['workouts'].first['id']]
    assert_equal @token.application_id, workout.created_by_oauth_application_id
    assert_equal @token.application_id, workout.sets.first.created_by_oauth_application_id
  end
end

# What the tool refuses, and how legibly, since a model has only the message to act on.
describe 'refusing to generate a week' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw)
  end

  it 'refuses a week the block does not have, in words a model can act on' do
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 9 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'no week 9'
  end

  it 'refuses a percentage it has no max for rather than inventing a load' do
    lift = @program['weeks'].first['days'].first['lifts'].first
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: lift['id'], percent_of_max: 80,
                                                  top_weight: nil })
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program['id'], week: 1 })
    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No estimated max'
  end
end

describe 'program isolation between accounts' do
  include Rack::Test::Methods

  before do
    @program = write_block(mint(scopes: %w[read write]).raw)
    @stranger = mint(scopes: %w[read write]).raw
  end

  it "never lists or reads another account's block" do
    call_tool('list_programs', raw: @stranger)
    assert_empty tool_result['structuredContent']['programs']
    call_tool('get_program', raw: @stranger, arguments: { program_id: @program['id'] })
    assert tool_result['isError']
  end

  it "never edits, deletes from, or generates another account's block" do
    lift = @program['weeks'].first['days'].first['lifts'].first
    call_tool('update_program_lift', raw: @stranger, arguments: { program_lift_id: lift['id'], top_weight: 999 })
    assert tool_result['isError']
    call_tool('delete_program_lift', raw: @stranger, arguments: { program_lift_id: lift['id'] })
    assert tool_result['isError']
    call_tool('generate_program_week', raw: @stranger, arguments: { program_id: @program['id'], week: 1 })
    assert tool_result['isError']
    assert_equal 155, Tectonic::ProgramLift[lift['id']].top_weight
  end

  it "never fetches another account's block by handle" do
    call_tool('fetch', raw: @stranger, arguments: { id: "program:#{@program['id']}" })
    assert tool_result['isError']
  end
end

