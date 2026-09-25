# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# What recent training says the next block should open at. #449.
#
# The pieces were all here and nothing put them in a line: sets carry RPE, `set_training_max`
# writes the reference, `exercise_history` reads completed work, and `OneRepMax` turns a rated
# set into a number. So the loop a lifter actually runs -- train a block, see what it cost,
# price the next one -- was four calls and a calculation done by hand, every time.
#
# It proposes and writes nothing, which is what the issue asks for and the only shape this
# could honestly take: which fraction of a demonstrated max a block opens at depends on what
# kind of block it is, and #263 settled that the app does not make that call.
module Proposing
  def a_movement(account_id, name: 'Bench Press')
    Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: true)
  end

  # A completed, rated set on a given day, which is the only thing a proposal reads. The set
  # is one argument rather than three keywords, because the list was one past what rubocop
  # will take and a hash of weight, reps and rpe reads as the set it is describing anyway.
  def lifted(account_id, exercise, set, days_ago: 7, is_warmup: false)
    workout = Tectonic::Workout.create(account_id:, date: Date.today - days_ago)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id,
                                weight: set[:weight], reps: set[:reps],
                                rpe: is_warmup ? nil : set[:rpe], is_warmup:, is_barbell: true,
                                # Lifted on the session's day, as a real one is. Stamped now,
                                # a set from 300 days ago read as today's once the history was
                                # dated by when each set was lifted.
                                **Tectonic::WorkoutSet.completion(true, at: workout.date))
  end

  def propose(raw, **arguments)
    call_tool('propose_training_maxes', raw:, arguments:)
  end

  def rows = tool_result['structuredContent']['movements']

  def row_for(name) = rows.find { |row| row['exercise'] == name }

  def said = tool_result.dig('content', 0, 'text')
end

describe 'proposing from recent training' do
  include Rack::Test::Methods
  include Proposing

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_movement(@token.account_id)
  end

  # 100 x 5 at RPE 7 restates to 6 reps, which is 78.6%, which is 127 lb. That is the set on
  # the reporting account that #466 admitted, and the arithmetic is the whole deliverable.
  it 'reads the set and says what it implies' do
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 })

    propose(@token.raw)

    assert_equal 127, row_for(@exercise.name)['proposed']
  end

  # "Showing its arithmetic" is the requirement. A proposal of 127 on its own is a number to
  # be believed; the set it came from is a number to be argued with.
  it 'shows the set it came from' do
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 })

    propose(@token.raw)

    assert_equal '100 lb x 5 at RPE 7, which is 6 reps from a single', row_for(@exercise.name)['from']
  end

  it 'says what is in force now and how far the proposal is from it' do
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 })
    Tectonic::TrainingMax.replace(@token.account_id, @exercise.id, 120)

    propose(@token.raw)

    assert_equal 120, row_for(@exercise.name)['current']
    assert_equal 'stated', row_for(@exercise.name)['current_source']
    assert_equal 7, row_for(@exercise.name)['change']
  end
end

# The one thing it must not do.
describe 'what proposing writes' do
  include Rack::Test::Methods
  include Proposing

  it 'writes nothing at all' do
    token = mint(scopes: %w[read write])
    exercise = a_movement(token.account_id)
    lifted(token.account_id, exercise, { weight: 100, reps: 5, rpe: 7 })
    Tectonic::TrainingMax.replace(token.account_id, exercise.id, 120)

    propose(token.raw)

    assert_equal 120, Tectonic::TrainingMax.for(account_id: token.account_id, exercise:).pounds
    assert_includes said, 'Nothing is written'
  end

  # A read scope is the enforcement rather than the description. A tool that proposes is a
  # tool a lifter should be able to hand out without handing out the ability to rewrite their
  # programme.
  it 'is a read' do
    token = mint(scopes: %w[read])
    exercise = a_movement(token.account_id)
    lifted(token.account_id, exercise, { weight: 100, reps: 5, rpe: 7 })

    propose(token.raw)

    refute tool_result['isError'], said
  end
end

# The bar `TrainingMax.derived` already holds. A proposal off a reading the app declines to
# trust itself would be the app suggesting a block be priced off its own guess.
describe 'what it refuses to propose from' do
  include Rack::Test::Methods
  include Proposing

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_movement(@token.account_id, name: 'Split Squat')
  end

  # 44 x 8 at RPE 7 restates to 9 reps -- readable since #438, and past CONFIDENT_REPS.
  it 'proposes nothing from a set nine reps from a single' do
    lifted(@token.account_id, @exercise, { weight: 44, reps: 8, rpe: 7 })

    propose(@token.raw)

    assert_nil row_for(@exercise.name)['proposed']
  end

  # Said rather than dropped. "Trained, and nothing in it can price a block" is a useful
  # answer about accessory work, and silence is not.
  it 'says why, and still counts the training' do
    lifted(@token.account_id, @exercise, { weight: 44, reps: 8, rpe: 7 })

    propose(@token.raw)

    assert_equal 1, row_for(@exercise.name)['trained_sets']
    assert_includes row_for(@exercise.name)['why_not'], 'close enough to a single'
  end
end

# A training max prices the next block, and what has ever been demonstrated is the wrong input
# for that: there is no lower bound on a lifetime best, so a single from three years ago
# outranks everything since. #307 makes the argument; this is where it bites.
describe 'the window it reads' do
  include Rack::Test::Methods
  include Proposing

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_movement(@token.account_id)
  end

  it 'ignores a heavier set from before the window' do
    lifted(@token.account_id, @exercise, { weight: 150, reps: 5, rpe: 7 }, days_ago: 300)
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 }, days_ago: 7)

    propose(@token.raw)

    assert_equal 127, row_for(@exercise.name)['proposed']
  end

  it 'reaches back further when asked' do
    lifted(@token.account_id, @exercise, { weight: 150, reps: 5, rpe: 7 }, days_ago: 300)
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 }, days_ago: 7)

    propose(@token.raw, weeks: 52)

    assert_equal 191, row_for(@exercise.name)['proposed']
  end
end

describe 'which movements it reports on' do
  include Rack::Test::Methods
  include Proposing

  before do
    @token = mint(scopes: %w[read write])
    @exercise = a_movement(@token.account_id)
    @other = a_movement(@token.account_id, name: 'Deadlift')
    lifted(@token.account_id, @exercise, { weight: 100, reps: 5, rpe: 7 })
    lifted(@token.account_id, @other, { weight: 200, reps: 5, rpe: 7 })
  end

  it 'covers everything trained in the window' do
    propose(@token.raw)

    assert_equal 2, rows.length
  end

  it 'narrows to one when asked' do
    propose(@token.raw, exercise: @exercise.name)

    assert_equal([@exercise.name], rows.map { |row| row['exercise'] })
  end

  # A movement nobody has trained in the window has nothing to say, and a row saying nothing
  # for every movement the account has ever created is a report nobody reads.
  it 'leaves out one nobody has trained lately' do
    a_movement(@token.account_id, name: 'Zercher')

    propose(@token.raw)

    refute_includes rows.map { |row| row['exercise'] }, 'Zercher'
  end
end

# A ramp rung is submaximal by definition, so counting one as training would tell a lifter
# their warmups are work. #211 settled what a warmup is worth.
describe 'what it counts as having been trained' do
  include Rack::Test::Methods
  include Proposing

  it 'does not count warmups toward the training in a window' do
    token = mint(scopes: %w[read write])
    exercise = a_movement(token.account_id)
    lifted(token.account_id, exercise, { weight: 45, reps: 5, rpe: nil }, is_warmup: true)
    lifted(token.account_id, exercise, { weight: 100, reps: 5, rpe: 7 })

    propose(token.raw)

    assert_equal 1, row_for(exercise.name)['trained_sets']
  end
end

