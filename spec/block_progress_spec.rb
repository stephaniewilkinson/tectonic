# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/mcp'
require_relative '../lib/tectonic/training_max'
require_relative '../lib/tectonic/goal'
require 'securerandom'
require 'date'

# "Am I on pace", which is the question a competitive lifter has and nothing could answer.
# #308.
#
# Three parts, and only one of them was data. A target to be on pace *for*; a way to say what
# a past block was really generated against; and the read over both. The middle one is the
# subtle half: `TrainingMax.for` takes the stated row where there is one and that row is
# upserted, so restating 315 as 325 used to make every block ever run report 325.
module BlockProgress
  def movement(account_id, name: "Lift #{SecureRandom.hex(4)}")
    Tectonic::Exercise.create(name:, account_id:, is_barbell: true)
  end

  # A block starting on a date, holding one week, one day, and one lift of a movement --
  # the least that makes a movement "prescribed in this block".
  def a_block(account_id, exercise, start_date:, name: 'Block')
    program = Tectonic::Program.create(account_id:, name:, start_date:, block: 1)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id,
                                 sets: 3, reps: 5, top_weight: 225)
    program
  end

  # A statement made at a chosen moment, which is what the log holds. Written directly
  # because TrainingMax.replace stamps CURRENT_TIMESTAMP, and every case here is about
  # something said before a block began.
  def said(account_id, exercise, pounds, at:)
    DB[:account_training_max_statements].insert(account_id:, exercise_id: exercise.id,
                                                pounds:, train_at_percent: 100, stated_at: at)
    DB[:account_training_maxes]
      .insert_conflict(target: %i[account_id exercise_id], update: { pounds:, stated_at: at })
      .insert(account_id:, exercise_id: exercise.id, pounds:, train_at_percent: 100, stated_at: at)
  end

  def openers(name)
    tool_result.dig('structuredContent', 'movements')
               .find { |row| row['exercise'] == name }['opened_at']
  end
end

# The core of it: what a block opened at is what was true when it started, not what is true
# now. Without the log this reported today's number for every block a lifter had ever run.
describe 'what each block opened at' do
  include Rack::Test::Methods
  include BlockProgress

  before do
    @minted = mint(scopes: %w[read write])
    @exercise = movement(@minted.account_id)
    said(@minted.account_id, @exercise, 315, at: Date.new(2026, 1, 5))
    a_block(@minted.account_id, @exercise, start_date: Date.new(2026, 2, 1), name: 'Winter')
    said(@minted.account_id, @exercise, 345, at: Date.new(2026, 5, 1))
    a_block(@minted.account_id, @exercise, start_date: Date.new(2026, 6, 1), name: 'Summer')
    call_tool('block_progress', raw: @minted.raw, arguments: {})
  end

  def opened(field) = openers(@exercise.name).map { |block| block[field] }

  it 'reports the number each block was actually generated against' do
    assert_equal [345, 315], opened('pounds')
  end

  it 'names the blocks, newest first' do
    assert_equal %w[Summer Winter], opened('name')
  end

  it 'says both were stated rather than estimated' do
    assert_equal %w[stated stated], opened('source')
  end

  # The trend in the sentence, because many clients render only the text. A movement with no
  # goal contributes no clause -- a tool that appended "no goal set" to every row would bury
  # the rows that have one.
  it 'puts the series in the prose, with no goal clause where none is set' do
    assert_includes tool_result.dig('content', 0, 'text'), '345 <- 315'
    refute_includes tool_result.dig('content', 0, 'text'), 'aiming at'
  end
end

# The two halves in one answer, which is the whole point of the tool: what you have been
# training against, and what you said you were training towards.
describe 'a movement carrying both a history and a goal' do
  include Rack::Test::Methods
  include BlockProgress

  before do
    @minted = mint(scopes: %w[read write])
    @exercise = movement(@minted.account_id)
    said(@minted.account_id, @exercise, 405, at: Date.today - 30)
    a_block(@minted.account_id, @exercise, start_date: Date.today, name: 'Now')
    Tectonic::Goal.replace(@minted.account_id, @exercise.id, 500, by_date: Date.today + 60)
    call_tool('block_progress', raw: @minted.raw, arguments: {})
  end

  def row = tool_result.dig('structuredContent', 'movements').first

  it 'reports the goal, the gap and the days beside the openers' do
    assert_equal 500, row.dig('goal', 'pounds')
    assert_equal 95, row.dig('goal', 'remaining_pounds')
    assert_equal 60, row.dig('goal', 'days_remaining')
  end

  it 'says all of it in the prose' do
    text = tool_result.dig('content', 0, 'text')

    assert_includes text, 'aiming at 500'
    assert_includes text, '95 lb to go'
    assert_includes text, '60 day(s) away'
  end
end

# The rule this must not break. #291 fixed a block's denominator at its start date and left
# restating a max as the escape hatch: restate, regenerate, and the block you are in moves.
# Resolving the stated branch as-of would have closed it, which is why the log is read only
# by reporting.
describe 'what the generator still resolves against' do
  include Rack::Test::Methods
  include BlockProgress

  it 'gives a restated max to a caller asking about today, whatever the log holds' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = movement(account_id)
    said(account_id, exercise, 315, at: Date.new(2026, 1, 5))
    said(account_id, exercise, 345, at: Date.new(2026, 5, 1))

    assert_equal 345, Tectonic::TrainingMax.for(account_id:, exercise:).pounds
  end

  # And the same call asked about a past date still answers the standing instruction, because
  # `for` deliberately does not pass `on` to the stated branch.
  it 'does not start answering as-of just because a history exists' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = movement(account_id)
    said(account_id, exercise, 315, at: Date.new(2026, 1, 5))
    said(account_id, exercise, 345, at: Date.new(2026, 5, 1))

    assert_equal 345, Tectonic::TrainingMax.for(account_id:, exercise:, on: Date.new(2026, 2, 1)).pounds
  end
end

# Clearing is a statement too. Without one, a block run after a clear would find the
# statement before it and report a number it was never generated against.
describe 'a block run after a stated max was cleared' do
  include Rack::Test::Methods
  include BlockProgress

  it 'reports the estimate rather than the number that was cleared' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    Tectonic::TrainingMax.replace(minted.account_id, exercise.id, 315)
    Tectonic::TrainingMax.replace(minted.account_id, exercise.id, nil)
    a_block(minted.account_id, exercise, start_date: Date.today, name: 'After')

    call_tool('block_progress', raw: minted.raw, arguments: {})

    refute_equal 315, openers(exercise.name).first['pounds']
  end

  # A movement never stated and never lifted has nothing to report, and says so with a nil
  # rather than by leaving the key out, so every row has the same shape.
  it 'reports nothing at all where there is neither a statement nor a set' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    a_block(minted.account_id, exercise, start_date: Date.today, name: 'Empty')

    call_tool('block_progress', raw: minted.raw, arguments: {})

    assert_nil openers(exercise.name).first['pounds']
  end
end

# A block that began before the lifter had said anything falls through to the derived
# reading, which is exactly what the app was generating against back then.
describe 'a block that began before anything was stated' do
  include Rack::Test::Methods
  include BlockProgress

  it 'reports the estimate for the early block and the statement for the later one' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    workout_id = DB[:workouts].insert(account_id: minted.account_id, date: Date.new(2026, 1, 1))
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 200, reps: 5,
                     is_warmup: false, is_completed: true, is_barbell: true)
    a_block(minted.account_id, exercise, start_date: Date.new(2026, 2, 1), name: 'Early')
    said(minted.account_id, exercise, 345, at: Date.new(2026, 5, 1))
    a_block(minted.account_id, exercise, start_date: Date.new(2026, 6, 1), name: 'Late')

    call_tool('block_progress', raw: minted.raw, arguments: {})

    assert_equal(%w[stated derived], openers(exercise.name).map { |block| block['source'] })
  end
end

describe 'setting what a movement is aiming at' do
  include Rack::Test::Methods
  include BlockProgress

  before do
    @minted = mint(scopes: %w[read write])
    @exercise = movement(@minted.account_id)
    Tectonic::TrainingMax.replace(@minted.account_id, @exercise.id, 405)
  end

  it 'stores the number and the date' do
    call_tool('set_goal', raw: @minted.raw,
                          arguments: { exercise: @exercise.name, pounds: 500, by_date: '2027-03-14' })

    goal = Tectonic::Goal.for(account_id: @minted.account_id, exercise_id: @exercise.id)

    assert_equal 500, goal.pounds
    assert_equal Date.new(2027, 3, 14), goal.by_date
  end

  # The gap is the only reason to set one, so it comes back without a second call.
  it 'says how far there is to go from what percentages use today' do
    call_tool('set_goal', raw: @minted.raw, arguments: { exercise: @exercise.name, pounds: 500 })

    assert_equal 95, tool_result.dig('structuredContent', 'remaining_pounds')
    assert_includes tool_result.dig('content', 0, 'text'), '95 lb to go'
  end

  # A target with no deadline is still a target, and insisting on one would be the app
  # requiring a plan the lifter has not made.
  it 'takes a goal with no date' do
    call_tool('set_goal', raw: @minted.raw, arguments: { exercise: @exercise.name, pounds: 500 })

    assert_nil tool_result.dig('structuredContent', 'by_date')
  end
end

describe 'dropping a goal over MCP' do
  include Rack::Test::Methods
  include BlockProgress

  it 'clears it when no pounds are sent' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)

    call_tool('set_goal', raw: minted.raw, arguments: { exercise: exercise.name, pounds: 500 })
    call_tool('set_goal', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_nil Tectonic::Goal.for(account_id: minted.account_id, exercise_id: exercise.id)
    assert_includes tool_result.dig('content', 0, 'text'), 'goal dropped'
  end
end

describe 'a goal that has already been passed' do
  include Rack::Test::Methods
  include BlockProgress

  # Signed rather than clamped: a lifter 15 lb past a target set in January wants to see
  # that, and a floor at zero would read as having only just arrived.
  it 'reports the overshoot as a negative gap' do
    minted = mint(scopes: %w[read write])
    exercise = movement(minted.account_id)
    Tectonic::TrainingMax.replace(minted.account_id, exercise.id, 420)

    call_tool('set_goal', raw: minted.raw, arguments: { exercise: exercise.name, pounds: 405 })

    assert_equal(-15, tool_result.dig('structuredContent', 'remaining_pounds'))
    assert_includes tool_result.dig('content', 0, 'text'), '15 lb past the goal'
  end
end

# A goal on a movement in no block still has to appear, or the tool is silent about the thing
# it was just told.
describe 'a goal on a movement not in any block' do
  include Rack::Test::Methods
  include BlockProgress

  it 'gets a row of its own' do
    minted = mint(scopes: %w[read write])
    in_block = movement(minted.account_id)
    aspiring = movement(minted.account_id)
    a_block(minted.account_id, in_block, start_date: Date.today)
    Tectonic::Goal.replace(minted.account_id, aspiring.id, 225)

    call_tool('block_progress', raw: minted.raw, arguments: {})
    named = tool_result.dig('structuredContent', 'movements').map { |row| row['exercise'] }

    assert_includes named, aspiring.name
    assert_includes named, in_block.name
  end
end

describe 'narrowing the read' do
  include Rack::Test::Methods
  include BlockProgress

  before do
    @minted = mint(scopes: %w[read write])
    @squat = movement(@minted.account_id)
    @bench = movement(@minted.account_id)
    a_block(@minted.account_id, @squat, start_date: Date.today)
    a_block(@minted.account_id, @bench, start_date: Date.today - 90)
  end

  it 'reports one movement when asked for one' do
    call_tool('block_progress', raw: @minted.raw, arguments: { exercise: @squat.name })

    assert_equal([@squat.name], tool_result.dig('structuredContent', 'movements').map { |r| r['exercise'] })
  end

  it 'reports as far back as it is asked to' do
    call_tool('block_progress', raw: @minted.raw, arguments: { blocks: 1 })

    assert_equal 1, tool_result.dig('structuredContent', 'blocks').length
  end

  it 'refuses a movement this account does not have' do
    call_tool('block_progress', raw: @minted.raw, arguments: { exercise: "Nope #{SecureRandom.hex(4)}" })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No exercise named'
  end
end

describe 'an account with no blocks at all' do
  include Rack::Test::Methods
  include BlockProgress

  it 'says there is nothing to compare rather than returning an empty list' do
    minted = mint(scopes: %w[read write])

    call_tool('block_progress', raw: minted.raw, arguments: {})

    assert_includes tool_result.dig('content', 0, 'text'), 'nothing to compare'
  end
end

describe 'another account s blocks and goals' do
  include Rack::Test::Methods
  include BlockProgress

  it 'are unreachable' do
    minted = mint(scopes: %w[read write])
    stranger = mint(scopes: %w[read write])
    theirs = movement(stranger.account_id)
    a_block(stranger.account_id, theirs, start_date: Date.today, name: 'Theirs')
    Tectonic::Goal.replace(stranger.account_id, theirs.id, 500)

    call_tool('block_progress', raw: minted.raw, arguments: {})

    assert_empty tool_result.dig('structuredContent', 'blocks')
    assert_empty tool_result.dig('structuredContent', 'movements')
  end
end

# The browser half: the goal sits one paragraph under the training max, because the two are
# read together and the gap between them is the whole of "am I on pace" on one movement.
describe 'the goal form on a movement' do
  include Rack::Test::Methods
  include RouteOwnership
  include BlockProgress

  before do
    @account_id = login
    @exercise = movement(@account_id)
    Tectonic::TrainingMax.replace(@account_id, @exercise.id, 405)
  end

  def save(fields)
    token = token_for_form("/exercises/#{@exercise.id}/", "/exercises/#{@exercise.id}/goal")
    post "/exercises/#{@exercise.id}/goal", { '_csrf' => token, **fields }
  end

  it 'stores what was typed' do
    save('pounds' => '500', 'by_date' => '2027-03-14')
    goal = Tectonic::Goal.for(account_id: @account_id, exercise_id: @exercise.id)

    assert_equal [500, Date.new(2027, 3, 14)], [goal.pounds, goal.by_date]
  end

  it 'shows it back with the distance to go' do
    save('pounds' => '500', 'by_date' => '2027-03-14')
    get "/exercises/#{@exercise.id}/"

    assert_includes last_response.body, '500 lb'
    assert_includes last_response.body, '95 lb from what percentages are worked out from today'
  end
end

# Blank clears, which is the rule the training max box above it follows. Two boxes on one page
# disagreeing about what an empty one means would be a trap.
describe 'a movement with no goal on it' do
  include Rack::Test::Methods
  include RouteOwnership
  include BlockProgress

  before do
    @account_id = login
    @exercise = movement(@account_id)
  end

  def token = token_for_form("/exercises/#{@exercise.id}/", "/exercises/#{@exercise.id}/goal")

  it 'says nothing is set' do
    get "/exercises/#{@exercise.id}/"

    assert_includes last_response.body, 'Nothing set'
  end

  it 'is what emptying the box leaves behind' do
    Tectonic::Goal.replace(@account_id, @exercise.id, 500)

    post "/exercises/#{@exercise.id}/goal", { '_csrf' => token, 'pounds' => '' }

    assert_nil Tectonic::Goal.for(account_id: @account_id, exercise_id: @exercise.id)
  end
end

