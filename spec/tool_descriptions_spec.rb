# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'reading_the_scale_spec' # ScaleReadings, and through it mcp_spec's mint and call_tool
require_relative '../lib/tectonic/mcp/server'

# What the tools say about themselves, held to the Connectors Directory's review criteria.
#
# "Describe what the tool does, and don't tell Claude how to behave." The descriptions used to
# carry coaching -- recommended rest ranges, "ask the lifter which convention", "use the gap to
# judge what a block should open at" -- and ran to 21,000 characters across the tools, which
# the policy's token-efficiency clause (5B) counts against a server. Both are held here so
# neither creeps back one helpful sentence at a time.
module ToolDescriptions
  # Phrases that instruct the model rather than describe the tool. Matched case-insensitively.
  INSTRUCTIONS = ['ask the lifter', 'rather than inventing', 'worth setting', 'you should',
                  'which you should', 'you want', 'use the gap', 'so write it to them',
                  'leave it out rather'].freeze
  LONGEST = 600

  def tools = Tectonic::MCP::ServerFactory::TOOLS

  def described = tools.to_h { |tool| [tool.tool_name, tool.description_value.to_s] }
end

describe 'the tool descriptions' do
  include ToolDescriptions

  it "are each short enough to read, at most #{ToolDescriptions::LONGEST} characters" do
    long = described.select { |_, text| text.length > ToolDescriptions::LONGEST }

    assert_empty long.transform_values(&:length), 'these descriptions are too long'
  end

  it 'describe what a tool does rather than telling the model how to behave' do
    described.each do |name, text|
      ToolDescriptions::INSTRUCTIONS.each do |phrase|
        refute_includes text.downcase, phrase, "#{name} tells the model how to behave: #{phrase.inspect}"
      end
    end
  end

  # Directory policy 2B: no functionality a description does not disclose. get_workout returns
  # heart rate from a matched watch recording, which is health data.
  it 'say so where a reply carries heart rate' do
    assert_includes described.fetch('get_workout'), 'heart rate'
  end
end

describe 'how much a health read returns at once' do
  include Rack::Test::Methods
  include ScaleReadings

  before { @token = mint(scopes: ['read']) }

  it 'caps the readings and says how to see the rest' do
    daily(@token.account_id, Array.new(12) { |day| 80 + (day / 10.0) })
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight', include_readings: true, limit: 5 })

    assert_equal 5, only_instrument['values'].length
    assert only_instrument['values_truncated']
    assert_includes prose, 'narrow from/to'
  end

  it 'says nothing about a cut when every reading fits' do
    daily(@token.account_id, [81.2, 81.5, 81.1])
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight', include_readings: true })

    assert_equal 3, only_instrument['values'].length
    refute only_instrument['values_truncated']
    refute_includes prose, 'narrow from/to'
  end
end

describe 'how many trend points are returned at once' do
  include Rack::Test::Methods
  include ScaleReadings

  before { @token = mint(scopes: ['read']) }

  it 'caps the daily series of a trend and says so' do
    days = Tectonic::MCP::Tools::BodyweightTrend::SERIES_LIMIT + 10
    daily(@token.account_id, Array.new(days) { 80.0 })
    call_tool('bodyweight_trend', raw: @token.raw,
                                  arguments: { include_series: true, from: (Date.today - days - 5).to_s })

    assert_equal Tectonic::MCP::Tools::BodyweightTrend::SERIES_LIMIT, only_instrument['series'].length
    assert only_instrument['series_truncated']
    assert_includes prose, 'narrow from/to'
  end
end

describe 'how many training blocks are listed at once' do
  include Rack::Test::Methods
  include ScaleReadings

  it 'lists the newest up to the limit and says how many there are' do
    token = mint(scopes: ['read'])
    3.times do |block|
      DB[:programs].insert(account_id: token.account_id, name: "Block #{block}", block:,
                           start_date: Date.today - (block * 28))
    end
    call_tool('list_programs', raw: token.raw, arguments: { limit: 2 })

    assert_equal(['Block 0', 'Block 1'], structured['programs'].map { |program| program['name'] })
    assert_equal [2, 3], structured.values_at('shown', 'total')
    assert_includes prose, 'showing the newest 2'
  end
end

