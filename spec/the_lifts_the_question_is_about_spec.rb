# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'block_progress_spec' # reuses its block, max and statement helpers
require 'securerandom'
require 'date'

# What `block_progress` reports on, and what it leaves out. #450 and #453.
#
# The tool answers "am I on pace" and the answer was buried. `subjects` takes everything
# prescribed in the blocks being reported, and most of a block is accessory work carrying no
# training max and no goal -- so those came back as rows of nulls. On the reporting account
# **thirty of thirty-three movements**, with the squat, the bench and the deadlift somewhere
# in the middle of them.
#
# That is the argument `aim` already makes about a clause -- "a tool that appended 'no goal
# set' to every row would bury the rows that have one" -- and it is truer of a whole row.
module LiftsInQuestion
  include BlockProgress

  # A block holding two movements: one worth reporting on and one that never will be.
  def a_block_of_two(account_id)
    main = movement(account_id, name: "Squat #{SecureRandom.hex(4)}")
    accessory = movement(account_id, name: "Clamshell #{SecureRandom.hex(4)}")
    program = a_block(account_id, main, start_date: Date.today)
    week = Tectonic::ProgramWeek.where(program_id: program.id).first
    day = Tectonic::ProgramDay.where(program_week_id: week.id).first
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: accessory.id,
                                 sets: 3, reps: 15, position: 1)
    [main, accessory, program]
  end

  def named
    tool_result.dig('structuredContent', 'movements').map { |row| row['exercise'] }
  end

  # A commanded set, written through a generated session because that is the only chain tying
  # a set to a block: a set belongs to a workout, which names its program day, week and block.
  def a_commanded_set(account_id, program, exercise, reps: 3, **how)
    day = Tectonic::ProgramDay.where(program_week_id:
      Tectonic::ProgramWeek.where(program_id: program.id).select(:id)).first
    workout = Tectonic::Workout.create(account_id:, date: Date.today, program_day_id: day.id)
    DB[:sets].insert(workout_id: workout.id, exercise_id: exercise.id, weight: 225, reps:,
                     is_barbell: true, is_warmup: false, is_completed: true,
                     is_commanded: how.fetch(:commanded, true), is_per_side: how.fetch(:per_side, false))
  end
end

describe 'the movements a pace question is about' do
  include Rack::Test::Methods
  include LiftsInQuestion

  before { @token = mint(scopes: %w[read write]) }

  it 'leaves out a movement with no max, no goal and no opener' do
    _, accessory, = a_block_of_two(@token.account_id)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    refute_includes named, accessory.name
  end

  it 'keeps the one carrying a max' do
    main, = a_block_of_two(@token.account_id)
    Tectonic::TrainingMax.replace(@token.account_id, main.id, 315)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_includes named, main.name
  end

  # #308 put accessories with targets in deliberately: a lifter bringing one up before it is
  # in any block must not be met with silence from the tool they set the goal for.
  it 'keeps one carrying only a goal' do
    _, accessory, = a_block_of_two(@token.account_id)
    Tectonic::Goal.replace(@token.account_id, accessory.id, 100)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_includes named, accessory.name
  end

  # Asking about a movement and being told nothing at all is worse than being told it has
  # nothing on it -- the empty answer is the true one to that question.
  it 'reports a movement named outright even with nothing on it' do
    _, accessory, = a_block_of_two(@token.account_id)
    call_tool('block_progress', raw: @token.raw, arguments: { exercise: accessory.name })

    assert_includes named, accessory.name
  end
end

# A heading with no rows under it reads as a tool that failed rather than one with nothing to
# report, which on a block of pure accessory work is the honest answer.
describe 'a set of blocks with nothing to compare' do
  include Rack::Test::Methods
  include LiftsInQuestion

  before { @token = mint(scopes: %w[read write]) }

  it 'says why it is empty rather than heading a list of nothing' do
    a_block_of_two(@token.account_id)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_includes tool_result.dig('content', 0, 'text'), 'no movement carries a training max'
  end
end

# The count #453 asks for, which the flag was added to answer and nothing answered. #311 put
# is_commanded on sets in 031 and get_workout's own note says the point of it was so a session
# "can answer 'how many commanded reps did this block contain'".
describe 'the commanded reps a block contains' do
  include Rack::Test::Methods
  include LiftsInQuestion

  before { @token = mint(scopes: %w[read write]) }

  it 'counts them on the block' do
    main, _, program = a_block_of_two(@token.account_id)
    a_commanded_set(@token.account_id, program, main, reps: 3)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_equal 3, tool_result.dig('structuredContent', 'blocks', 0, 'commanded_reps')
  end

  it 'says so in the prose, which is all some clients render' do
    main, _, program = a_block_of_two(@token.account_id)
    a_commanded_set(@token.account_id, program, main, reps: 3)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_includes tool_result.dig('content', 0, 'text'), 'Commanded reps'
  end

  # Per side counts twice on Volume::WORKED_REPS' rule: eight per side is sixteen commands.
  it 'counts a per-side rep on both sides' do
    main, _, program = a_block_of_two(@token.account_id)
    a_commanded_set(@token.account_id, program, main, reps: 8, per_side: true)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_equal 16, tool_result.dig('structuredContent', 'blocks', 0, 'commanded_reps')
  end
end

# What it says about a block nobody commanded a rep in, which is every block so far.
describe 'a block with no commanded reps' do
  include Rack::Test::Methods
  include LiftsInQuestion

  before { @token = mint(scopes: %w[read write]) }

  # Zero rather than absent, so a reader can tell "none" from "field I forgot to look at".
  it 'is zero for a block with none' do
    a_block_of_two(@token.account_id)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    assert_equal 0, tool_result.dig('structuredContent', 'blocks', 0, 'commanded_reps')
  end

  # And silent in the prose, because every block anybody has trained so far has none, and a
  # "0 commanded reps" line on every answer is the noise `aim` refuses to print about goals.
  it 'says nothing in the prose where no rep was commanded' do
    main, _, program = a_block_of_two(@token.account_id)
    a_commanded_set(@token.account_id, program, main, commanded: false)
    call_tool('block_progress', raw: @token.raw, arguments: {})

    refute_includes tool_result.dig('content', 0, 'text'), 'Commanded reps'
  end
end

