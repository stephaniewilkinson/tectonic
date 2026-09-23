# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# The three read-only tools over what the scale said. #519.
#
# Every fixture here is inserted straight into `health_metrics`, the way
# connecting_a_scale_spec already does. Nothing in this file calls Withings: #518 owns the
# fetching and these tools own the reading, and a spec that needed a live API call to check
# arithmetic would be testing the wrong half and would fail on a runner with no credentials.
module ScaleReadings
  # The three tools, named once. A method rather than a bare constant reference inside a
  # describe, because a constant defined in a module is not resolved lexically from a block
  # that merely includes it -- which is the trick mcp_annotations_spec already uses.
  TOOLS = %w[health_readings bodyweight_trend body_composition].freeze

  # What a reading comes from unless a spec says otherwise.
  INSTRUMENT = { unit: 'kg', source: 'withings' }.freeze

  def scale_tools = TOOLS

  # This time of day, n days ago. Anchored on now rather than on a fixed date because all
  # three tools default to a window ending today, and a fixture pinned to 2027 would fall
  # outside it the moment a default was exercised.
  def morning(days_ago)
    (Time.now - (days_ago * 86_400)).round
  end

  # One row. `external_id` is unique per insert because 041 puts a unique index on
  # [source, external_id] to make #518's re-fetching idempotent, and a spec writing two rows
  # with the same one would fail on the constraint rather than on its own assertion.
  def reading(account_id, metric:, value:, at:, **instrument)
    row = INSTRUMENT.merge(instrument)
    DB[:health_metrics].insert(account_id:, metric:, value:, measured_at: at, **row,
                               external_id: "#{row[:source]}-#{metric}-#{SecureRandom.hex(6)}")
  end

  # A run of daily readings: `values` is read newest first, so a fixture reads the way the
  # tools answer.
  def daily(account_id, values, metric: 'weight', **instrument)
    values.each_with_index { |value, ago| reading(account_id, metric:, value:, at: morning(ago), **instrument) }
  end

  # A whole body composition group at one instant, which is how a scale writes one.
  def weigh_in(account_id, at:, **metrics)
    instrument = { unit: metrics.delete(:unit), source: metrics.delete(:source) }.compact
    metrics.each { |metric, value| reading(account_id, metric: metric.to_s, value:, at:, **instrument) }
  end

  def structured = tool_result['structuredContent']

  def prose = tool_result.dig('content', 0, 'text')

  def instruments = structured['instruments']

  def only_instrument = instruments.fetch(0)
end

describe 'asking for a metric that has been recorded' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.2, 81.5, 81.1, 81.8, 81.4])
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight' })
  end

  # The sample size and the window are what turn a count into a claim: five readings over
  # five days and five over five months say different things about the same number.
  it 'reports how many readings there were and what they span' do
    assert_equal 5, only_instrument['readings']
    assert_equal 4, only_instrument.dig('window', 'days')
  end

  it 'names the instrument that produced them rather than reporting a bare number' do
    assert_equal %w[withings kg], only_instrument.values_at('source', 'unit')
  end

  # The default is a summary, because a year of a twice-daily scale is hundreds of rows
  # saying one thing and it arrives in somebody's context window.
  it 'leaves the rows out unless they were asked for' do
    refute only_instrument.key?('values')
  end

  it 'says in the text how a caller gets the rows' do
    assert_includes prose, 'include_readings'
  end
end

describe 'asking for the rows themselves' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.2, 81.5, 81.1, 81.8, 81.4])
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight', include_readings: true })
  end

  it 'hands over one per reading' do
    assert_equal 5, only_instrument['values'].length
  end

  # numeric(10,3) comes back from Sequel as a BigDecimal, which serialises to JSON as the
  # string "0.812e2" -- #256's bug, waiting in every new payload.
  it 'sends numbers a client can do arithmetic on rather than BigDecimals' do
    assert(only_instrument['values'].all? { |row| row['value'].is_a?(Numeric) })
    refute_match(/\d[eE][-+]?\d/, prose)
  end
end

# The rule 041 put `source` on the row for: a scale's figure and a caliper's are different
# measurements wearing one name, so a tool that averaged them would be averaging two things
# that do not average.
describe 'readings from two instruments' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.2, 81.5, 81.1], source: 'withings')
    daily(@token.account_id, [80.0, 80.2, 80.1], source: 'manual')
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight' })
  end

  it 'answers once per source instead of once overall' do
    assert_equal %w[manual withings], instruments.map { |view| view['source'] }.sort
  end

  it 'gives each source its own count' do
    assert_equal([3, 3], instruments.map { |view| view['readings'] })
  end

  it 'reports only the one asked for when a source is named' do
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight', source: 'manual' })

    assert_equal(['manual'], instruments.map { |view| view['source'] })
  end
end

# The half of the same argument that is easier to walk into, because one source supplies
# both: a lifter who flips the Withings app to pounds leaves a history where 81.4 and 179.5
# are the same morning, and a mean over the two is 130 of nothing.
describe 'one source that changed units' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.4, 81.2], unit: 'kg')
    daily(@token.account_id, [179.5, 179.0], unit: 'lb')
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'weight' })
  end

  it 'keeps the kilograms and the pounds apart' do
    assert_equal %w[kg lb], instruments.map { |view| view['unit'] }.sort
  end

  it 'never produces a figure between the two' do
    assert(instruments.none? { |view| (100..170).cover?(view['latest']['value']) })
  end
end

# A model that asked for the wrong name and a model whose scale has not synced want opposite
# next moves, and an empty list tells them apart from neither.
describe 'asking for a metric nothing has been recorded under' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.2, 81.5])
    call_tool('health_readings', raw: @token.raw, arguments: { metric: 'bodyweight' })
  end

  it 'says there were none' do
    assert_empty instruments
  end

  it 'lists the names this account does hold' do
    assert_equal({ 'weight' => 2 }, structured['metrics_held'])
    assert_includes prose, 'weight (2)'
  end

  it 'says so plainly for an account with nothing at all' do
    call_tool('health_readings', raw: mint(scopes: ['read']).raw, arguments: { metric: 'weight' })

    assert_includes prose, 'Nothing has been recorded for this account yet.'
  end
end

# The scoping guarantee RequestContext exists for, checked on the new dataset rather than
# assumed from the old ones.
describe 'another account on the same scale brand' do
  include Rack::Test::Methods
  include ScaleReadings

  it 'is unreachable' do
    mine = mint(scopes: ['read'])
    daily(mine.account_id, [81.2])
    daily(new_account, [99.9, 99.8, 99.7])

    call_tool('health_readings', raw: mine.raw, arguments: { metric: 'weight' })

    assert_equal 1, only_instrument['readings']
    assert_equal 81.2, only_instrument['latest']['value']
  end
end

# "The scale is the instrument; the app is not." Asserted rather than asserted in a comment:
# a later edit that added an upsert to any of these would still pass every test above.
describe 'the three tools together' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    weigh_in(@token.account_id, at: morning(0), weight: 81.4, fat_mass: 22.7, lean_mass: 58.7)
  end

  it 'is offered by the server, so none of them is unreachable' do
    offered = Tectonic::MCP::ServerFactory::TOOLS.map(&:tool_name)

    assert_empty scale_tools - offered
  end

  it 'declares the read scope, which is what marks it read-only to a client' do
    registered = Tectonic::MCP::ServerFactory::TOOLS.select { |tool| scale_tools.include?(tool.tool_name) }

    assert_equal [:read], registered.map(&:scope).uniq
  end

  it 'records no measurement of its own' do
    stored = DB[:health_metrics].count
    scale_tools.each { |name| call_tool(name, raw: @token.raw, arguments: { metric: 'weight' }.slice(*required(name))) }

    assert_equal stored, DB[:health_metrics].count
  end

  # health_readings is the only one of the three that insists on a metric.
  def required(name) = name == 'health_readings' ? [:metric] : []
end

# The tool that answers "am I gaining", which is the question a single reading cannot answer
# and two readings a day apart answer wrongly.
describe 'a bodyweight that is falling steadily' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    # 80.7 this morning up to 82.0 a fortnight ago: a tenth a day, and nothing else moving.
    daily(@token.account_id, (0..13).map { |ago| (807 + ago) / 10.0 })
    call_tool('bodyweight_trend', raw: @token.raw, arguments: {})
  end

  it 'defaults to weight, since that is the metric the question is about' do
    assert_equal 'weight', structured['metric']
  end

  it 'reports the rolling mean at each end of the window rather than two raw readings' do
    assert_equal 82.0, only_instrument['opened']['value']
    assert_equal 81.0, only_instrument['latest']['value']
  end

  it 'reports the change and the observed rate' do
    assert_equal(-1.0, only_instrument['change'])
    assert_equal(-0.54, only_instrument['per_week'])
  end

  it 'says nothing about what that rate ought to be' do
    refute_match(/should|target|goal/i, prose)
  end
end

# The band is the number that decides whether the change above means anything at all.
describe 'the noise band on a steady fall' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, (0..13).map { |ago| (807 + ago) / 10.0 })
    call_tool('bodyweight_trend', raw: @token.raw, arguments: {})
  end

  it 'reports how far the number moves between readings' do
    assert_in_delta 0.1, only_instrument['day_to_day'], 0.01
  end

  it 'says the change is larger than that movement' do
    assert only_instrument['change_exceeds_day_to_day']
    assert_includes prose, 'larger than the noise'
  end
end

# The case the tool exists for: a number that jumps around without going anywhere, which two
# readings a day apart would read as a confident 1.0 kg of progress.
describe 'a bodyweight that is only bouncing' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, (0..13).map { |ago| ago.even? ? 81.0 : 82.0 })
    call_tool('bodyweight_trend', raw: @token.raw, arguments: {})
  end

  it 'measures a band as wide as the bouncing' do
    assert_in_delta 1.0, only_instrument['day_to_day'], 0.01
  end

  it 'refuses to call the change more than noise' do
    refute only_instrument['change_exceeds_day_to_day']
  end

  # Many clients render only the text, so the clause that stops the misreading has to be in
  # it rather than only in a boolean nobody displays. #262's lesson, applied to #519's point.
  it 'says so in the text, beside the number' do
    assert_includes prose, 'inside the noise'
    assert_match(/moves about ±/, prose)
  end
end

describe 'the trend on more readings than anybody wants to read' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, (0..29).map { |ago| 81.0 + (ago / 100.0) })
  end

  it 'keeps the daily points out of the answer by default' do
    call_tool('bodyweight_trend', raw: @token.raw, arguments: {})

    refute only_instrument.key?('series')
  end

  it 'hands over one point per day when they are asked for' do
    call_tool('bodyweight_trend', raw: @token.raw, arguments: { include_series: true })
    days = only_instrument['series'].map { |point| point['on'] }

    assert_equal 30, days.length
    assert_equal days.length, days.uniq.length
  end

  it 'smooths over the window it was asked for' do
    call_tool('bodyweight_trend', raw: @token.raw, arguments: { days: 30, include_series: true })

    assert_equal 30, only_instrument['window_days']
    assert_equal 30, only_instrument['series'].last['readings']
  end
end

describe 'a trend with one reading in it' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.4])
    call_tool('bodyweight_trend', raw: @token.raw, arguments: {})
  end

  # A zero would read as a plateau somebody could act on; one morning has not held steady,
  # it has not been asked twice.
  it 'reports no change rather than a change of nothing' do
    assert_nil only_instrument['change']
    assert_nil only_instrument['per_week']
  end

  it 'admits it cannot say how much of that is noise' do
    assert_nil only_instrument['day_to_day']
    assert_nil only_instrument['change_exceeds_day_to_day']
    assert_includes prose, 'Too few readings close together'
  end
end

describe 'the trend with nothing to read' do
  include Rack::Test::Methods
  include ScaleReadings

  it 'says a trend needs more than one morning' do
    call_tool('bodyweight_trend', raw: mint(scopes: ['read']).raw, arguments: {})

    assert_empty instruments
    assert_includes prose, 'not a direction'
  end
end

describe 'a body composition weigh-in' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    (0..5).each do |ago|
      weigh_in(@token.account_id, at: morning(ago), weight: 81.4 + (ago / 10.0),
                                  fat_mass: 22.7 + (ago / 20.0), lean_mass: 58.7)
    end
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  # The set, not a figure: a percentage without the weight it came from invites a comparison
  # against one taken at a different bodyweight.
  it 'returns the masses and the bodyweight they were taken at, together' do
    assert_equal 81.4, only_instrument.dig('weight', 'value')
    assert_equal 22.7, only_instrument.dig('fat_mass', 'value')
    assert_equal 58.7, only_instrument.dig('lean_mass', 'value')
  end

  it 'stamps them all with the one weigh-in they came from' do
    assert only_instrument['measured_at']
  end

  it 'works the percentage out from that weigh-in and says that is what it did' do
    assert_equal 27.9, only_instrument.dig('body_fat_percent', 'value')
    assert_equal 'derived from fat mass and weight', only_instrument.dig('body_fat_percent', 'basis')
  end

  it 'keeps the unit it was stored in rather than converting to the pounds this app lifts in' do
    assert_equal 'kg', only_instrument.dig('weight', 'unit')
  end
end

# #519's sentence, in as many words: "27.9%, day-to-day variation around ±1.5%" rather than a
# bare number, because a bare one invites a comparison the instrument cannot resolve.
describe 'the percentage a weigh-in reports' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    (0..5).each do |ago|
      weigh_in(@token.account_id, at: morning(ago), weight: 81.4 + (ago / 10.0),
                                  fat_mass: 22.7 + (ago / 20.0), lean_mass: 58.7)
    end
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  it 'carries the variation and the number of weigh-ins it was measured over' do
    assert only_instrument.dig('body_fat_percent', 'day_to_day')
    assert_equal 6, only_instrument.dig('body_fat_percent', 'weigh_ins')
  end

  it 'puts both in the text, where a client that renders nothing else will show them' do
    assert_match(/body fat 27\.9% .*day-to-day variation around ±/, prose)
  end

  it 'says nothing about what the figures ought to be' do
    refute_match(/should|target|goal|ideal/i, prose)
  end

  # A scale's own fat_ratio is another spelling of a figure that is reported either way,
  # rather than a fourth measurement, so a weigh-in without one is not missing anything.
  it 'does not call a derived percentage a missing measurement' do
    refute_includes only_instrument['missing'], 'fat_ratio'
  end
end

# The reason a weigh-in is a cluster of rows at one instant rather than a day's worth of
# them. A lifter who steps on again in the evening is exactly who this would mislead.
describe 'a second weigh-in later the same day' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    weigh_in(@token.account_id, at: morning(0) - 43_200, weight: 81.4, fat_mass: 22.7, lean_mass: 58.7)
    reading(@token.account_id, metric: 'weight', value: 82.6, at: morning(0))
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  it 'reads the latest weigh-in rather than the latest of each metric' do
    assert_equal 82.6, only_instrument.dig('weight', 'value')
  end

  it 'refuses to borrow the morning fat mass for the evening weight' do
    assert_nil only_instrument['fat_mass']
    assert_nil only_instrument['body_fat_percent']
  end

  it 'names what that weigh-in did not record' do
    assert_includes only_instrument['missing'], 'fat_mass'
    assert_includes prose, 'Not recorded at this weigh-in'
  end
end

# Withings computes a ratio inside the scale from the impedance it actually saw. Recomputing
# it from two rounded masses would produce a second number a tenth away from the first, and a
# reader holding both would have no way to know they were one measurement.
describe 'a scale that reports its own fat ratio' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    at = morning(0)
    weigh_in(@token.account_id, at:, weight: 81.4, fat_mass: 22.7)
    reading(@token.account_id, metric: 'fat_ratio', value: 28.4, unit: '%', at:)
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  it 'reports the measured figure rather than one of its own' do
    assert_equal 28.4, only_instrument.dig('body_fat_percent', 'value')
    assert_equal 'measured', only_instrument.dig('body_fat_percent', 'basis')
  end
end

describe 'a fat mass with no weight beside it' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    reading(@token.account_id, metric: 'fat_mass', value: 22.7, at: morning(0))
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  # Dividing by the last weight it can find is the comparison across bodyweights #519 exists
  # to prevent, with the app making it rather than the reader.
  it 'declines to work out a percentage at all' do
    assert_nil only_instrument['body_fat_percent']
  end
end

describe 'a caliper reading and a scale reading in the same window' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    weigh_in(@token.account_id, at: morning(1), weight: 81.4, fat_mass: 22.7, source: 'withings')
    weigh_in(@token.account_id, at: morning(0), weight: 81.4, fat_mass: 19.5, source: 'manual')
    call_tool('body_composition', raw: @token.raw, arguments: {})
  end

  it 'reports each instrument on its own line' do
    assert_equal %w[manual withings], instruments.map { |view| view['source'] }.sort
  end

  it 'never produces one percentage from the two' do
    percentages = instruments.map { |view| view.dig('body_fat_percent', 'value') }

    assert_equal [24.0, 27.9], percentages.sort
  end
end

describe 'body composition asked for as of a past day' do
  include Rack::Test::Methods
  include ScaleReadings

  before do
    @token = mint(scopes: ['read'])
    weigh_in(@token.account_id, at: morning(10), weight: 83.0, fat_mass: 24.0)
    weigh_in(@token.account_id, at: morning(0), weight: 81.4, fat_mass: 22.7)
  end

  it 'answers with the last weigh-in at or before that day' do
    call_tool('body_composition', raw: @token.raw, arguments: { on: (Date.today - 5).strftime('%Y-%m-%d') })

    assert_equal 83.0, only_instrument.dig('weight', 'value')
  end
end

describe 'body composition with nothing recorded' do
  include Rack::Test::Methods
  include ScaleReadings

  it 'says a weigh-in has to arrive first' do
    call_tool('body_composition', raw: mint(scopes: ['read']).raw, arguments: {})

    assert_empty instruments
    assert_includes prose, 'before there is anything to read back'
  end
end

