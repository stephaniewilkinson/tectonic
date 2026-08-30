# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/program_generator'
require_relative '../lib/tectonic/training_max'
require 'securerandom'

# A percentage can be of another movement's max. #295.
#
# It always resolved against the lift's own exercise, so a Paused Squat at 80% took 80% of
# Paused Squat history -- a different and much lower number than the squat it is a variation
# of, and one that came out light in a way that looks correct. Sheiko prices every deadlift
# variation off the competition deadlift; 5/3/1 prices supplemental work off the main lift's
# training max. Neither was expressible.
module PricedOff
  def scratch_account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  def movement(account_id, name: "Lift #{SecureRandom.hex(4)}")
    Tectonic::Exercise.create(name:, account_id:, is_barbell: true)
  end

  # A one-week block with one percentage lift, optionally priced off another movement.
  def block_pricing(account_id, exercise, percent:, off: nil)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}",
                                       start_date: Date.today - 7)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: (Date.today - 7).wday, focus: 'Squat')
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 5, percent_of_max: percent, progression: 'percent',
                                 is_barbell: true, is_main: true, percent_of_exercise_id: off&.id)
    program
  end

  def top_of(program)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    Tectonic::WorkoutSet.where(workout_id: workout.id, is_warmup: false).map(&:weight).max
  end
end

describe 'a variation priced off the movement it varies' do
  include PricedOff

  before do
    @account_id = scratch_account
    @competition = movement(@account_id, name: "Back Squat #{SecureRandom.hex(4)}")
    @variation = movement(@account_id, name: "Paused Squat #{SecureRandom.hex(4)}")
    Tectonic::TrainingMax.replace(@account_id, @competition.id, 400)
  end

  # The whole of #295: 80% of the squat, not 80% of a variation that has never been trained.
  it 'takes the percentage of the named movement' do
    assert_equal 320, top_of(block_pricing(@account_id, @variation, percent: 80, off: @competition))
  end

  # Without the pointer the variation has nothing of its own to read, which is the visible
  # half of the same gap -- and the message names both movements so the refusal is legible.
  it 'refuses without one, and says which movement the lift was waiting on' do
    error = assert_raises(ArgumentError) { top_of(block_pricing(@account_id, @variation, percent: 80)) }

    assert_match(/no training max for/i, error.message)
  end

  # A reference the lift can read while its own movement is untrained is the difference
  # between a block that generates and one that does not.
  it 'generates a movement that has never been lifted' do
    assert_operator top_of(block_pricing(@account_id, @variation, percent: 80, off: @competition)), :>, 0
  end
end

# Null means "its own max", which is what every row meant before this and what most go on
# meaning. The column being absent is the fallback rather than a value chosen for it.
describe 'a lift with no movement named' do
  include PricedOff

  it 'is still priced off its own max' do
    account_id = scratch_account
    exercise = movement(account_id)
    Tectonic::TrainingMax.replace(account_id, exercise.id, 300)

    assert_equal 240, top_of(block_pricing(account_id, exercise, percent: 80))
  end
end

# What a percentage is taken of and what the bar can be loaded to are two questions, and
# borrowing both from the reference is the way this goes wrong: a dumbbell variation priced
# off a barbell max should round to the dumbbell rule.
describe 'a variation loaded differently from the movement it is priced off' do
  include PricedOff

  it 'rounds to its own rack rule rather than the reference lift' do
    account_id = scratch_account
    barbell = movement(account_id, name: "Bench #{SecureRandom.hex(4)}")
    Tectonic::TrainingMax.replace(account_id, barbell.id, 200)
    dumbbell = Tectonic::Exercise.create(name: "DB Press #{SecureRandom.hex(4)}", account_id:,
                                         is_barbell: false)
    program = block_pricing(account_id, dumbbell, percent: 63, off: barbell)
    days = Tectonic::ProgramDay.where(program_week_id: program.week(1).id).select(:id)
    Tectonic::ProgramLift.where(program_day_id: days).update(is_barbell: false)

    # 63% of 200 is 126, and a dumbbell rounds in fives rather than to a loadable barbell.
    assert_equal 125, top_of(program)
  end
end

describe 'naming the movement over MCP' do
  include Rack::Test::Methods
  include PricedOff

  before do
    @minted = mint(scopes: %w[read write])
    @squat = movement(@minted.account_id, name: "Back Squat #{SecureRandom.hex(4)}")
    call_tool('create_program', raw: @minted.raw,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1, days: [{ weekday: 1, lifts: [variation] }] }] })
    @program = tool_result['structuredContent']
  end

  def variation
    { exercise: 'Paused Squat', sets: 3, reps: 5, percent_of_max: 80, percent_of: @squat.name }
  end

  it 'reads the movement back by name' do
    assert_equal @squat.name, @program['weeks'].first['days'].first['lifts'].first['percent_of']
  end

  # "70% of max" on a deficit deadlift means two different loads depending which max was
  # meant, so the prose names it where it is not the lift's own.
  it 'says whose max the percentage is of' do
    call_tool('get_program', raw: @minted.raw, arguments: { program_id: @program['id'] })

    assert_includes tool_result.dig('content', 0, 'text'), "80% of #{@squat.name} max"
  end
end

# Null is how a lift goes back to being priced off its own max, which is what the column
# being absent has always meant -- so the two spellings of "its own" stay one value.
describe 'clearing the movement a lift is priced off' do
  include Rack::Test::Methods
  include PricedOff

  it 'goes back to its own max' do
    minted = mint(scopes: %w[read write])
    squat = movement(minted.account_id, name: "Back Squat #{SecureRandom.hex(4)}")
    call_tool('create_program', raw: minted.raw,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1, days: [{ weekday: 1,
                                                                           lifts: [{ exercise: 'Paused Squat',
                                                                                     sets: 3, reps: 5,
                                                                                     percent_of_max: 80,
                                                                                     percent_of: squat.name }] }] }] })
    lift = tool_result['structuredContent']['weeks'].first['days'].first['lifts'].first

    call_tool('update_program_lift', raw: minted.raw,
                                     arguments: { program_lift_id: lift['id'], percent_of: nil })

    assert_nil tool_result['structuredContent']['percent_of']
  end
end

# A reference with nothing to reference is a field that reads as doing something and does
# not, so it is refused by name rather than stored and ignored.
describe 'naming a movement on a lift that is not priced as a percentage' do
  include Rack::Test::Methods
  include PricedOff

  it 'is refused, and says what is missing' do
    minted = mint(scopes: %w[read write])
    call_tool('create_program', raw: minted.raw,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1,
                                                       days: [{ weekday: 1,
                                                                lifts: [{ exercise: 'Paused Squat', sets: 3,
                                                                          reps: 5, top_weight: 225,
                                                                          percent_of: 'Back Squat' }] }] }] })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'needs percent_of_max beside it'
  end
end

