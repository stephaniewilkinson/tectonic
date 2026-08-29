# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative 'mcp_program_tools_spec' # and its write_block; idempotent
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# The half of an MCP response a person actually reads.
#
# Every tool answers twice: `structuredContent` for a client that parses, and `content`
# for one that renders. The structured half has been right for as long as Presenter has
# existed. The prose half was interpolating the column straight, and weight is
# numeric(7,2), so Sequel hands back a BigDecimal and BigDecimal#to_s is "0.155e3". A
# session read back through a connector that shows only the text looked like this:
#
#   Deadlift 0.155e3x3   Bench Press 0.1e3x3   Front Squat 0.92e2x3
#
# and plenty of connectors show only the text. #256.
#
# The second half of this file is #258: `text` and `metadata` describing the same workout
# differently, because one read the cached association and the other read the database.
module McpProse
  # Scientific notation, which is what a BigDecimal reaching a sentence looks like. Two
  # digits with an `e` between them appears in no weight, rep count, date or id this app
  # produces, so anything matching is the bug.
  NOTATION = /\d[eE][-+]?\d/
  # Where the guard at the foot of this file looks, and what makes an interpolation of a
  # weight acceptable: `set[:weight]` is a presented hash, and `weight(...)` and
  # `load_phrase` are the presenter itself. A model's column reaching a string with none
  # of those around it is the bug.
  TOOL_SOURCES = File.expand_path('../lib/tectonic/mcp/tools/*.rb', __dir__)
  PRESENTED = /Presenter\.|load_phrase|\bweight\(|\[:\w*weight\]/

  def refute_notation(text)
    refute_match NOTATION, text, "a weight reached the prose as a BigDecimal: #{text}"
  end

  def prose
    tool_result.dig('content', 0, 'text')
  end

  # Letters only. A hex suffix is unique and also occasionally spells scientific notation
  # -- "Squat c9c7e8a1" contains 7e8 -- which fails the check above for a reason that is
  # in the fixture rather than in the app. Mapping the digits out keeps the uniqueness and
  # loses the false positive.
  def unique
    SecureRandom.hex(4).tr('0-9', 'g-p')
  end

  def logged(token, weight)
    exercise = Tectonic::Exercise.create(account_id: token.account_id, name: "Squat #{unique}",
                                         is_barbell: true)
    workout = Tectonic::Workout.create(account_id: token.account_id, date: Date.today)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight:, reps: 5,
                                is_warmup: false, is_completed: false)
  end
end

describe 'the weight create_set reads back' do
  include Rack::Test::Methods
  include McpProse

  before { @token = mint(scopes: %w[read write]) }

  it 'says 225 rather than 0.225e3' do
    Tectonic::Exercise.create(account_id: @token.account_id, name: 'Probe Squat', is_barbell: true)
    call_tool('create_set', raw: @token.raw, arguments: { exercise: 'Probe Squat', weight: 225, reps: 5 })

    refute_notation prose
    assert_includes prose, 'Logged 225x5'
  end

  # Plates.numeric gives a whole number back as an Integer and a half as a Float, so a
  # fix that only stringified would pass the case above and fail this one.
  it 'says 137.5 rather than 0.1375e3' do
    Tectonic::Exercise.create(account_id: @token.account_id, name: 'Probe Press', is_barbell: true)
    call_tool('create_set', raw: @token.raw, arguments: { exercise: 'Probe Press', weight: 137.5, reps: 3 })

    refute_notation prose
    assert_includes prose, 'Logged 137.5x3'
  end
end

describe 'the weight an edit reads back' do
  include Rack::Test::Methods
  include McpProse

  before { @token = mint(scopes: %w[read write]) }

  it 'says it plainly when a set is completed' do
    set = logged(@token, 185)
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: set.id })

    refute_notation prose
    assert_includes prose, '185x5'
  end

  it 'says it plainly when a set is edited' do
    set = logged(@token, 95)
    call_tool('update_set', raw: @token.raw, arguments: { set_id: set.id, weight: 102.5 })

    refute_notation prose
    assert_includes prose, '102.5x5'
  end
end

describe 'the weight a read tool reads back' do
  include Rack::Test::Methods
  include McpProse

  before { @token = mint(scopes: %w[read write]) }

  it 'says the heaviest plainly in an exercise history' do
    set = logged(@token, 155)
    set.update(is_completed: true)
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: set.exercise.name })

    refute_notation prose
    assert_includes prose, 'heaviest 155'
  end

  # Found while fixing the notation on this same line. The column is nullable and
  # unweighted work stores nothing in it, so `rows.map(&:weight).max` met a nil among
  # BigDecimals and raised rather than answering. A pull-up done both weighted and not is
  # an ordinary history question and it failed outright.
  it 'answers a movement done both weighted and bodyweight, rather than raising on the nil' do
    set = logged(@token, 45)
    set.update(is_completed: true)
    Tectonic::WorkoutSet.create(workout_id: set.workout_id, exercise_id: set.exercise_id,
                                weight: nil, reps: 8, is_warmup: false, is_completed: true)
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: set.exercise.name })

    refute tool_result['isError'], "exercise_history refused: #{prose}"
    assert_includes prose, 'heaviest 45'
  end
end

# #258. `workout_document` built its metadata from a fresh query and its text from the
# association Sequel had cached on the instance, and nothing invalidates that cache when
# a set is written through some other object. So the two halves of one response described
# the same workout differently, and did so exactly when a client had just edited
# something -- which is when it is most likely to be reading the answer back.
describe 'the two halves of one workout' do
  include Rack::Test::Methods
  include McpProse

  before do
    @token = mint(scopes: %w[read write])
    @set = logged(@token, 95)
  end

  # fetch answers with the whole document, so its `text` is the prose half and its
  # `metadata` is the structured half -- the two that disagreed.
  def fetched
    call_tool('fetch', raw: @token.raw, arguments: { id: "workout:#{@set.workout_id}" })
    tool_result['structuredContent']
  end

  it 'describe the same sets after an edit in the same session' do
    call_tool('update_set', raw: @token.raw, arguments: { set_id: @set.id, weight: 105 })
    document = fetched

    listed = document['metadata']['sets'].map { |set| set['weight'] }

    assert_includes document['text'], '105x5'
    refute_includes document['text'], '95x5'
    assert_equal [105], listed
  end

  # The same divergence inside the structured half alone: `completed` was counted off the
  # cached association while `sets` was listed off a fresh query, so one hash could say
  # two of three completed over a list showing three.
  it 'agree on how many sets were completed' do
    call_tool('complete_set', raw: @token.raw, arguments: { set_id: @set.id })
    metadata = fetched['metadata']

    assert_equal metadata['sets'].count { |set| set['is_completed'] }, metadata['completed']
  end
end

describe 'the sentence a fetched workout carries' do
  include Rack::Test::Methods
  include McpProse

  before { @token = mint(scopes: %w[read write]) }

  it 'reads no BigDecimal into it either' do
    set = logged(@token, 155)
    call_tool('fetch', raw: @token.raw, arguments: { id: "workout:#{set.workout_id}" })

    refute_notation tool_result['structuredContent']['text']
  end
end

# The guard the next prose site needs, since the five that were wrong were wrong the same
# way and a sixth would be too. Source rather than behaviour: a spec cannot call a tool
# that does not exist yet, and this catches it the moment it is written.
# The half #256 reported as already correct, and where that turned out not to hold. A
# set's weight goes through Presenter.weight in view_set; a program lift's did not, and
# migration 012 made program_lifts.top_weight numeric(7,2) too. So a prescribed load
# reached structuredContent as the JSON string "0.155e3" where a client had every reason
# to expect the number 155 -- the same bug, in the payload rather than the prose, found by
# printing that payload in #262.
describe 'the load a program lift carries in the structured payload' do
  include Rack::Test::Methods
  include McpProse

  it 'is a number rather than a string spelling one' do
    token = mint(scopes: %w[read write])
    program = write_block(token.raw)
    load = program['weeks'].first['days'].first['lifts'].first['top_weight']

    assert_kind_of Numeric, load, "top_weight came back as #{load.inspect}"
    assert_equal 155, load
  end
end

describe 'every tool that puts a weight in a sentence' do
  it 'runs it through the presenter first' do
    Dir[McpProse::TOOL_SOURCES].each do |tool|
      File.read(tool).scan(/#\{[^}]*weight[^}]*\}/).each do |interpolation|
        assert_match McpProse::PRESENTED, interpolation, "#{File.basename(tool)} interpolates #{interpolation} raw"
      end
    end
  end
end

