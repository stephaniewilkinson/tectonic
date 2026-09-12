# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec'               # token minting and call_tool
require_relative 'mcp_program_tools_spec' # and write_block / block_arguments
require 'securerandom'

# Writing a prescribed rest over MCP. #281.
#
# The assistant is where most prescriptions are actually written, so a column the block editor
# can set and the tools cannot is a column half the app cannot reach. These assert the three
# write paths carry it, that it comes back on a read, and that a nonsense value is refused by
# name rather than reaching the schema -- a constraint violation reaches a client as a database
# error and reads as the tool being broken.
describe 'prescribing a rest over MCP' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @day = @program['weeks'].first['days'].first
  end

  def add_lift(arguments)
    call_tool('add_program_lift', raw: @raw,
                                  arguments: { program_day_id: @day['id'], exercise: 'Overhead Press',
                                               sets: 3, reps: 5, top_weight: 65 }.merge(arguments))
  end

  it 'writes one given to add_program_lift' do
    add_lift(rest_seconds: 180)

    assert_equal 180, tool_result['structuredContent']['rest_seconds']
  end

  it 'reads back as nothing where none was given' do
    add_lift({})

    assert_nil tool_result['structuredContent']['rest_seconds']
  end
end

# Changing one on a lift that already exists, which is where most prescriptions actually get
# set: a block is written first and the rests are tuned against how the first week felt.
describe 'revising a prescribed rest over MCP' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @program = write_block(@raw)
    @day = @program['weeks'].first['days'].first
  end

  it 'sets one on a lift already written' do
    lift = @day['lifts'].first
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: lift['id'], rest_seconds: 300 })

    assert_equal 300, tool_result['structuredContent']['rest_seconds']
  end

  # Clearing it is how a lifter goes back to the measured median, so null has to mean
  # something here rather than reading as "unchanged".
  it 'clears one back to the measured median with null' do
    lift = @day['lifts'].first
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: lift['id'], rest_seconds: 300 })
    call_tool('update_program_lift', raw: @raw,
                                     arguments: { program_lift_id: lift['id'], rest_seconds: nil })

    assert_nil tool_result['structuredContent']['rest_seconds']
  end
end

# Reading one back, which is what lets an assistant see what it already prescribed rather than
# overwriting it blind.
describe 'reading a prescribed rest back over MCP' do
  include Rack::Test::Methods

  it 'comes back from get_program' do
    raw = mint(scopes: %w[read write]).raw
    program = write_block(raw)
    lift = program['weeks'].first['days'].first['lifts'].first
    call_tool('update_program_lift', raw:,
                                     arguments: { program_lift_id: lift['id'], rest_seconds: 240 })
    call_tool('get_program', raw:, arguments: { program_id: program['id'] })
    written = tool_result['structuredContent']['weeks'].first['days'].first['lifts'].first

    assert_equal 240, written['rest_seconds']
  end
end

# Refused by name, and the bound named in the refusal. A bad prescription is not one bad row:
# the generator copies it onto every working set of every week the block generates.
describe 'a rest the tools will not write' do
  include Rack::Test::Methods

  before do
    @raw = mint(scopes: %w[read write]).raw
    @day = write_block(@raw)['weeks'].first['days'].first
  end

  def add_with_rest(seconds)
    call_tool('add_program_lift', raw: @raw,
                                  arguments: { program_day_id: @day['id'], exercise: 'Overhead Press',
                                               sets: 3, reps: 5, top_weight: 65, rest_seconds: seconds })
  end

  it 'refuses a rest of no time' do
    add_with_rest(0)

    assert_includes tool_result['content'].first['text'], 'Rest'
  end

  it 'refuses one longer than any real prescription' do
    add_with_rest(5400)

    assert_includes tool_result['content'].first['text'], 'Rest'
  end

  # The refusal is the tool's, so it names the bound rather than arriving as a database error
  # that reads as the tool being broken. Asserted on the whole sentence, because "out of
  # range" without the range in it is a refusal a model cannot act on.
  it 'names the range it refused against' do
    add_with_rest(5400)

    assert_includes tool_result['content'].first['text'], 'Rest 5400 is out of range; use 5-1800 seconds.'
  end
end

