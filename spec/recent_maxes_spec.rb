# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/volume'
require 'securerandom'

# What recent training implies, beside what has ever been demonstrated. #307.
#
# `estimated_1rm` means the most that has ever been demonstrated, which is the right meaning
# for a max and is also the one that goes stale without saying so: a single from three years
# ago outranks everything since, and nothing about the number says it is old. #293 answered
# half of that by carrying the date. This is the other half -- the same arithmetic over the
# last 12, 26 and 52 weeks, so a reader can see 315 from 2023 sitting next to a twelve-week
# best of 290 and draw the obvious conclusion themselves.
module RecentMaxes
  # A movement with one heavy single long ago and lighter work since, which is the shape the
  # whole issue is about: the lifetime figure is true and current form is somewhere else.
  def a_layoff(account_id, best: 315, lately: 255)
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(account_id, exercise, weight: best, days_ago: 400)
    lifted(account_id, exercise, weight: lately, days_ago: 14)
    exercise
  end

  # RPE 10 at one rep, so the estimate is the weight on the bar and every assertion below is
  # about windows rather than about the 1RM formula, which #294 already specs.
  def lifted(account_id, exercise, weight:, days_ago:, reps: 1)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today - days_ago)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, reps:, rpe: 10,
                     is_warmup: false, is_completed: true, is_barbell: true,
                     completed_at: Time.now - (days_ago * 86_400))
  end

  def readings(exercise, account_id)
    exercise.recent_readings(account_id:, windows: Tectonic::Volume::WINDOWS)
            .to_h { |reading| [reading[:weeks], reading] }
  end
end

describe 'a movement last at its best a long time ago' do
  include RecentMaxes

  before { @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x') }

  it 'still reports the lifetime best as the lifetime best' do
    exercise = a_layoff(@account_id)

    assert_equal 315, exercise.estimated_max(account_id: @account_id).to_i
  end

  # The whole point of the issue in one assertion: the two numbers differ, and the difference
  # is the thing a reader is after.
  it 'reports what the last twelve weeks support instead' do
    exercise = a_layoff(@account_id)

    assert_equal 255, readings(exercise, @account_id)[12][:pounds].to_i
  end

  # 400 days is outside all three windows, so every one of them sees only the recent work.
  it 'leaves the old single out of every window it falls outside' do
    exercise = a_layoff(@account_id)
    found = readings(exercise, @account_id)

    Tectonic::Volume::WINDOWS.each do |weeks|
      assert_equal 255, found[weeks][:pounds].to_i, "the #{weeks}-week window reached back too far"
    end
  end
end

describe 'a window that reaches the older work' do
  include RecentMaxes

  it 'reports the better number, because a window is still a best rather than a latest' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(account_id, exercise, weight: 315, days_ago: 200) # inside 52 weeks, outside 12 and 26
    lifted(account_id, exercise, weight: 255, days_ago: 7)

    found = readings(exercise, account_id)

    assert_equal 255, found[12][:pounds].to_i
    assert_equal 315, found[52][:pounds].to_i
  end
end

# A number off one set and a number off forty are not the same claim, and the pounds alone
# cannot tell them apart.
describe 'how much a window rests on' do
  include RecentMaxes

  it 'counts the sets behind each reading' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    3.times { lifted(account_id, exercise, weight: 225, days_ago: 3) }
    lifted(account_id, exercise, weight: 225, days_ago: 300)

    found = readings(exercise, account_id)

    assert_equal 3, found[12][:sets]
    assert_equal 4, found[52][:sets]
  end

  # An answer rather than an omission. On a movement somebody has stopped training, "nothing
  # in the last twelve weeks" is the most useful thing this can say, and a caller that gets
  # three windows every time can say it without checking whether the key is there.
  it 'still returns the window when nothing was lifted inside it' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(account_id, exercise, weight: 225, days_ago: 500)

    found = readings(exercise, account_id)

    assert_equal Tectonic::Volume::WINDOWS.length, found.length
    assert_nil found[12][:pounds]
    assert_equal 0, found[12][:sets]
  end
end

# Another account's lifting must never reach this number. The scope is the same one
# estimated_max already goes through, and this is what says so out loud.
describe 'a library movement two accounts both train' do
  include RecentMaxes

  it 'windows only the account that asked' do
    mine = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    theirs = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    exercise = Tectonic::Exercise.create(account_id: nil, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(mine, exercise, weight: 225, days_ago: 3)
    lifted(theirs, exercise, weight: 405, days_ago: 3)

    assert_equal 225, readings(exercise, mine)[12][:pounds].to_i
  ensure
    # A library row has no account behind it, and the teardown deliberately keeps those -- so
    # this one has to take itself away, and its sets have to go first or the foreign key
    # refuses. Left behind, it is a movement with two accounts' lifting on it that every later
    # spec in the suite can see.
    Tectonic::WorkoutSet.where(exercise_id: exercise&.id).delete
    Tectonic::Exercise.where(id: exercise&.id).delete
  end
end

# #256 again, in the field it had not reached yet. `weight` is numeric(7,2), Sequel hands back
# a BigDecimal, and BigDecimal serialises to JSON as the string "0.275e3" -- so the prose read
# correctly while the structured number a client parses was a string nobody could do
# arithmetic on. Asserted as a type, because every assertion about its value passed while it
# was wrong.
describe 'the number a client actually parses' do
  include Rack::Test::Methods
  include RecentMaxes

  it 'is a number rather than scientific notation in a string' do
    minted = mint(scopes: %w[read write])
    exercise = a_layoff(minted.account_id)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_kind_of Numeric, tool_result.dig('structuredContent', 'recent').first['pounds']
  end
end

describe 'exercise_history on a movement with a layoff behind it' do
  include Rack::Test::Methods
  include RecentMaxes

  it 'carries all three windows in the payload' do
    minted = mint(scopes: %w[read write])
    exercise = a_layoff(minted.account_id)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    weeks = tool_result.dig('structuredContent', 'recent').map { |reading| reading['weeks'] }

    assert_equal Tectonic::Volume::WINDOWS, weeks
  end

  # Many clients render only the text, which is #262's lesson -- and a lifetime best that
  # reads as current is exactly the misreading this issue is about.
  it 'says them in the prose too, with the sample size' do
    minted = mint(scopes: %w[read write])
    exercise = a_layoff(minted.account_id)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_includes tool_result.dig('content', 0, 'text'), 'last 12 weeks imply 255 (1 set)'
  end
end

# The windows follow `to` for the same reason estimated_1rm does: asking about a block that
# finished in March should be answered with what was true in March, not with the twelve weeks
# before today.
describe 'exercise_history asked about a date in the past' do
  include Rack::Test::Methods
  include RecentMaxes

  it 'windows back from the date asked about rather than from today' do
    minted = mint(scopes: %w[read write])
    exercise = Tectonic::Exercise.create(account_id: minted.account_id,
                                         name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(minted.account_id, exercise, weight: 275, days_ago: 200)

    call_tool('exercise_history', raw: minted.raw,
                                  arguments: { exercise: exercise.name,
                                               to: (Date.today - 190).strftime('%Y-%m-%d') })

    twelve = tool_result.dig('structuredContent', 'recent').first

    assert_equal 12, twelve['weeks']
    assert_equal 275, twelve['pounds'].to_i, 'a set ten days before the date asked about is inside twelve weeks'
  end
end

describe 'a movement with nothing a max can be read from' do
  include Rack::Test::Methods
  include RecentMaxes

  # Three empty clauses on every bodyweight movement in the account would be noise, and the
  # lifetime figure above has already said everything that can be said.
  it 'says nothing about windows it cannot read' do
    minted = mint(scopes: %w[read write])
    exercise = Tectonic::Exercise.create(account_id: minted.account_id, name: "Plank #{SecureRandom.hex(4)}")
    workout_id = DB[:workouts].insert(account_id: minted.account_id, date: Date.today)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, measure: 'time', duration_seconds: 60,
                     reps: nil, is_warmup: false, is_completed: true)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    refute_includes tool_result.dig('content', 0, 'text'), 'Recently:'
  end
end

# The narrowing arguments are about which sets are *listed*. The windows are context for
# those rows rather than a summary of them, so they do not move when the list does.
describe 'the windows against the arguments that narrow the list' do
  include Rack::Test::Methods
  include RecentMaxes

  it 'reports the full windows even when only one set is asked for' do
    minted = mint(scopes: %w[read write])
    exercise = Tectonic::Exercise.create(account_id: minted.account_id,
                                         name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    lifted(minted.account_id, exercise, weight: 225, days_ago: 3)
    lifted(minted.account_id, exercise, weight: 275, days_ago: 10)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name, limit: 1 })

    assert_equal 1, tool_result.dig('structuredContent', 'shown')
    assert_equal 275, tool_result.dig('structuredContent', 'recent').first['pounds'].to_i
    assert_equal 2, tool_result.dig('structuredContent', 'recent').first['sets']
  end
end

