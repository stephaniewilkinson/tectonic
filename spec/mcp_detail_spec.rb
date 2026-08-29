# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative 'mcp_program_tools_spec' # and its block_arguments/write_block; idempotent
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# #262: three read tools answered with a summary where their own descriptions promised
# detail. get_program's description says it "returns the ids the program edit tools take"
# and its text was one sentence carrying no id at all; list_workouts promised set counts
# and a status per workout and answered "You have 8 workout(s) in this range."
#
# The structured payload carried all of it the whole time. That is not the same as being
# answered, because a great many MCP clients render only `content` -- so a tool that
# promises ids and visibly prints a sentence reads as broken, and the reasonable next
# move is to go and find the ids some other way, which nothing documented either.
#
# Asserted on the text rather than on the structured half, deliberately: the structured
# half was never the problem and pinning it here would say nothing.
module McpDetail
  def prose
    tool_result.dig('content', 0, 'text')
  end

  def logged_session(account_id, sets: 3, completed: 1)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: Date.today)
    sets.times do |index|
      Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 155,
                                  reps: 5, is_warmup: false, is_completed: index < completed)
    end
    workout
  end
end

describe 'what get_program prints' do
  include Rack::Test::Methods
  include McpDetail

  before do
    @token = mint(scopes: %w[read write])
    @program = write_block(@token.raw, weeks: 2)
    call_tool('get_program', raw: @token.raw, arguments: { program_id: @program['id'] })
  end

  # The one the description explicitly promises, and the one it did not keep.
  it 'names the id of every object its edit tools take one of' do
    week = @program['weeks'].first
    day = week['days'].first

    assert_includes prose, "program #{@program['id']}"
    assert_includes prose, "week id #{week['id']}"
    assert_includes prose, "day id #{day['id']}"
    day['lifts'].each { |lift| assert_includes prose, "lift #{lift['id']}:" }
  end

  it 'prints every week, not only the first' do
    @program['weeks'].each { |week| assert_includes prose, "Week #{week['number']}" }
  end

  it 'gives each lift its sets, reps and load, which is what the description offers' do
    assert_includes prose, 'Back Squat 4x5 @ 155'
    assert_includes prose, 'Barbell Row 3x8 @ 95'
  end

  it 'says which day of the week a day falls on, and the date it falls on' do
    assert_includes prose, 'Monday 2027-01-04'
  end
end

describe 'what list_workouts prints' do
  include Rack::Test::Methods
  include McpDetail

  before do
    @token = mint(scopes: %w[read write])
    @workout = logged_session(@token.account_id, sets: 3, completed: 1)
    call_tool('list_workouts', raw: @token.raw, arguments: {})
  end

  it 'lists the workouts rather than counting them' do
    assert_includes prose, "[workout #{@workout.id}]"
    assert_includes prose, Date.today.strftime('%Y-%m-%d')
  end

  # The description promises set counts and a status. Both were in the structured half
  # only, so a client showing the text had to make a second call per workout to learn
  # anything the first one had already been told to say.
  it 'says how much of each was done, and where it sits in the plan' do
    assert_includes prose, '1 of 3 set(s) done'
    assert_includes prose, 'performed'
  end

  it 'still leads with the total, since a withheld count is the point of it' do
    assert_match(/\A[^\n]*workout\(s\) in this range\./, prose)
  end
end

# get_workout was reported as inconsistent -- "sometimes a one-line summary, sometimes the
# full set list". It is not, and was not: it has printed a headline and then every set for
# as long as it has had a headline. The likely source of the report is `fetch`, which
# answers with a document whose text is one line by design.
#
# Pinned anyway rather than argued with, because it is the behaviour the ticket is about
# and nothing was holding it.
describe 'what get_workout prints' do
  include Rack::Test::Methods
  include McpDetail

  it 'prints a line for every set, not a count of them' do
    token = mint(scopes: %w[read write])
    workout = logged_session(token.account_id, sets: 3, completed: 1)
    call_tool('get_workout', raw: token.raw, arguments: { workout_id: workout.id })

    listed = prose.lines.count { |line| line.include?('155x5') }

    assert_equal 3, listed
    assert_includes prose, '3 set(s), 1 completed'
  end
end

# The other half of #262: the route to an id was undocumented, so an assistant that
# needed one found search and fetch by trial. Named in the server instructions, which
# every client is handed once, rather than repeated on fifteen tools.
describe 'what the server tells a client on connecting' do
  include Rack::Test::Methods

  it 'says where the ids the edit tools take come from' do
    instructions = Tectonic::MCP::Config.instructions

    assert_includes instructions, 'list_workouts'
    assert_includes instructions, 'search'
    assert_includes instructions, 'fetch'
  end
end

