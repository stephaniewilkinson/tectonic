# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_program_tools_spec' # block_arguments, write_block; idempotent require

# Things a directory reviewer, or a model, would try that used to go wrong.
describe 'a long block, read back' do
  include Rack::Test::Methods

  it 'shows eight weeks in full and says how many more there are' do
    raw = mint(scopes: %w[read write]).raw
    id = write_block(raw, weeks: 10)['id']
    call_tool('get_program', raw:, arguments: { program_id: id })

    assert_equal 8, tool_result.dig('structuredContent', 'weeks').size
    assert_equal 2, tool_result.dig('structuredContent', 'weeks_not_shown')
    assert_includes tool_result.dig('content', 0, 'text'), '2 later week(s) not shown; pass week to read one.'
  end

  it 'reads one week when asked for it' do
    raw = mint(scopes: %w[read write]).raw
    id = write_block(raw, weeks: 10)['id']
    call_tool('get_program', raw:, arguments: { program_id: id, week: 10 })

    assert_equal([10], tool_result.dig('structuredContent', 'weeks').map { |week| week['number'] })
  end
end

describe 'a fractional load on a lift already written' do
  include Rack::Test::Methods

  # Weights are pounds and may be fractional everywhere else; this one schema said integer.
  it 'is accepted by update_program_lift' do
    raw = mint(scopes: %w[read write]).raw
    lift = write_block(raw).dig('weeks', 0, 'days', 0, 'lifts', 0, 'id')
    call_tool('update_program_lift', raw:, arguments: { program_lift_id: lift, top_weight: 137.5 })

    refute tool_result['isError'], tool_result.dig('content', 0, 'text')
  end
end

describe 'an argument Postgres cannot store' do
  include Rack::Test::Methods

  # A NUL is valid JSON and invalid jsonb. It used to fail the audit row inside the crash
  # handler and surface as the gem's bare "Internal error".
  it 'still gets an answer from the tool rather than a generic error' do
    call_tool('create_exercise', raw: mint(scopes: %w[read write]).raw,
                                 arguments: { name: "Squat\u0000 #{SecureRandom.hex(3)}" })

    refute_includes tool_result.dig('content', 0, 'text').to_s, 'Internal error'
  end
end

# Inputs that used to be accepted or to crash, now refused with something a caller can act on.
describe 'arguments past what the app keeps' do
  include Rack::Test::Methods

  def raw = @raw ||= mint(scopes: %w[read write]).raw

  def refusal = [tool_result['isError'], tool_result.dig('content', 0, 'text')]

  it 'refuses an id too large to exist rather than crashing' do
    call_tool('get_program', raw:, arguments: { program_id: 99_999_999_999 })
    assert_equal [true, 'program_id is out of range: no program_id that large exists.'], refusal
  end

  it 'refuses a date no session could have' do
    call_tool('create_workout', raw:, arguments: { date: '0001-01-01' })
    assert refusal.first
    assert_includes refusal.last, 'outside the dates this app keeps'
  end

  it 'refuses an exercise name longer than any real one' do
    call_tool('create_exercise', raw:, arguments: { name: 'x' * 101 })
    assert_equal [true, 'An exercise name can be at most 100 characters.'], refusal
  end
end

