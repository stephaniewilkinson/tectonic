# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'dumbbell_rack_spec' # reuses its rack helpers; idempotent require
require_relative '../lib/tectonic/equipment'
require_relative '../lib/tectonic/program_generator'
require 'securerandom'
require 'date'

# How many dumbbells a movement is done with, and why one shelf gives two answers. #439.
#
# 033 gave dumbbells 007's arithmetic: a handle stands where the bar does and `pairs` counts
# what goes on **one** dumbbell. That is exactly right for a single-arm row and exactly wrong
# for a dumbbell bench press, and nothing could tell them apart -- so both rounded against the
# single's list and the two-handed movements got weights that cannot be built.
#
# A size has to appear on both ends of every handle in use. One dumbbell spends a pair of a
# size; two dumbbells spend two pairs. On the reporting account's shelf -- a 4 lb handle with
# pairs of 10, 5 and 2.5 -- half the range disappears:
#
#     one dumbbell:   4, 9, 14, 19, 24, 29, 34, 39, 44, 49, 54, 59, 64, 69, 74, 79
#     two dumbbells:  4, 9, 14, 19, 24, 29, 34, 39
module TwoDumbbells
  include DumbbellRack

  # The reporting account's shelf, exactly.
  def the_reported_shelf(account_id)
    with_dumbbells(account_id, handle: 4, plates: { 10 => 2, 5 => 2, 2.5 => 3 })
  end

  def a_movement(account_id, dumbbell_count:)
    Tectonic::Exercise.create(account_id:, name: "DB #{SecureRandom.hex(4)}",
                              is_barbell: false, dumbbell_count:)
  end

  # A one-day block of this movement, generated, and the working weights it came out at.
  def a_block(account_id, exercise, top_weight: 45)
    day = a_day(account_id)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 2, reps: 8, top_weight:, progression: 'linear',
                                 is_main: false, is_barbell: false)
    workout = Tectonic::ProgramGenerator.new(day.program_week.program).generate(1).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }
  end

  def a_day(account_id)
    program = Tectonic::Program.create(account_id:, name: 'B', start_date: Date.today, is_ascending: false)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
  end
end

describe 'how far one shelf goes' do
  include TwoDumbbells

  before { @rack = the_reported_shelf(an_account) }

  it 'reaches 79 with one dumbbell in hand' do
    assert_equal 79, @rack.dumbbell_totals(1).max
  end

  # Not 79 halved, which is the arithmetic worth being explicit about: the handle is not
  # halved, only the plates on it, so the pair tops out at 39 rather than 39.5.
  it 'reaches only 39 with two' do
    assert_equal 39, @rack.dumbbell_totals(2).max
  end

  # Every weight a pair can make, a single can make too. That is the property the default
  # rests on: assuming two can only ever be cautious, never impossible.
  it 'can build anything on one that it can build on two' do
    assert_empty @rack.dumbbell_totals(2) - @rack.dumbbell_totals(1)
  end

  # The reported case, both ways round. 44 is an ordinary single-arm row and cannot be a
  # dumbbell bench at all.
  it 'answers the same prescription differently for one hand and for two' do
    assert_equal 44, @rack.loadable(45, is_barbell: false, dumbbells: 1)
    assert_equal 39, @rack.loadable(45, is_barbell: false, dumbbells: 2)
  end

  # Integer division doing real work: three pairs of 2.5 make one usable pair across two
  # handles rather than one and a half, and a size that will not go round at all drops out
  # instead of being enumerated with a count of nothing.
  it 'does not hand out half a pair' do
    rack = with_dumbbells(an_account, handle: 10, plates: { 5 => 1 })

    assert_equal [10, 20], rack.dumbbell_totals(1).sort
    assert_equal [10], rack.dumbbell_totals(2)
  end

  # The bar is not touched by any of this, which is #369's rule about two inventories not
  # reaching into one another, said again now there is a third number involved.
  it 'ignores the count on a barbell' do
    assert_equal @rack.loadable(137, is_barbell: true, dumbbells: 1),
                 @rack.loadable(137, is_barbell: true, dumbbells: 2)
  end
end

# Where the count comes from, and what it means to have never given one.
describe 'a movement that has not said how many dumbbells' do
  include TwoDumbbells

  it 'is read as two, which is the cautious answer rather than the likely one' do
    exercise = Tectonic::Exercise.create(account_id: an_account, name: "DB #{SecureRandom.hex(4)}",
                                         is_barbell: false)

    assert_nil exercise.dumbbell_count
    assert_equal 2, exercise.dumbbells
    assert exercise.unanswered_dumbbells?
  end

  # The column keeps the difference between "nobody said" and "somebody said two", which a
  # schema default would have thrown away -- and that difference is the whole of what makes it
  # possible to ask a lifter to review the ones still unanswered.
  it 'is distinguishable from one deliberately set to two' do
    exercise = a_movement(an_account, dumbbell_count: 2)

    assert_equal 2, exercise.dumbbells
    refute exercise.unanswered_dumbbells?
  end

  it 'is not asked of a barbell movement at all' do
    exercise = Tectonic::Exercise.create(account_id: an_account, name: "Squat #{SecureRandom.hex(4)}",
                                         is_barbell: true)

    refute exercise.unanswered_dumbbells?
  end
end

# And the whole way through, which is the part that was actually broken: the count has to
# reach the weights the generator writes, not merely exist on the movement.
describe 'generating a block of dumbbell work' do
  include TwoDumbbells

  before { @account_id = an_account }

  it 'writes a single-arm movement at the weight the shelf can build for one hand' do
    the_reported_shelf(@account_id)

    assert_equal [44, 44], a_block(@account_id, a_movement(@account_id, dumbbell_count: 1))
  end

  # The bug: this used to come out at 44, which is a dumbbell this shelf cannot make twice.
  it 'writes a two-handed movement at a weight it can build twice' do
    the_reported_shelf(@account_id)

    assert_equal [39, 39], a_block(@account_id, a_movement(@account_id, dumbbell_count: 2))
  end
end

# Through the form a lifter actually uses, which is where a fix like this goes quietly missing:
# the column can exist, the arithmetic can be right, and the one page that sets it can still be
# posting nothing.
describe 'saying how many dumbbells on the movement page' do
  include Rack::Test::Methods
  include RouteOwnership
  include TwoDumbbells

  before do
    @account_id = login
    the_reported_shelf(@account_id)
    @exercise = Tectonic::Exercise.create(account_id: @account_id, name: "DB #{SecureRandom.hex(4)}",
                                          is_barbell: false)
  end

  def save(count)
    post '/exercises', { 'id' => @exercise.id.to_s, 'name' => @exercise.name,
                         'dumbbell_count' => count, '_csrf' => token_for("/exercises/#{@exercise.id}/edit") }
  end

  it 'offers the answer on the form' do
    get "/exercises/#{@exercise.id}/edit"

    assert_includes last_response.body, 'name="dumbbell_count"'
  end
end

describe 'what the movement page does with the answer' do
  include Rack::Test::Methods
  include RouteOwnership
  include TwoDumbbells

  before do
    @account_id = login
    the_reported_shelf(@account_id)
    @exercise = Tectonic::Exercise.create(account_id: @account_id, name: "DB #{SecureRandom.hex(4)}",
                                          is_barbell: false)
  end

  def save(count)
    post '/exercises', { 'id' => @exercise.id.to_s, 'name' => @exercise.name,
                         'dumbbell_count' => count, '_csrf' => token_for("/exercises/#{@exercise.id}/edit") }
  end

  it 'records it' do
    save('1')

    assert_equal 1, @exercise.refresh.dumbbell_count
  end

  # Blank has to stay sayable, because "not said" is what makes it possible to ask a lifter
  # which movements still want an answer.
  it 'takes a blank as not said rather than as a number' do
    save('1')
    save('')

    assert_nil @exercise.refresh.dumbbell_count
    assert @exercise.refresh.unanswered_dumbbells?
  end
end

# The check constraint allows only 1 and 2, so anything else has to be caught before the write
# rather than after: refused in the database it would surface as a 500 on a Save button.
describe 'a count that is not one or two' do
  include Rack::Test::Methods
  include RouteOwnership
  include TwoDumbbells

  it 'never reaches the database' do
    account_id = login
    exercise = Tectonic::Exercise.create(account_id:, name: "DB #{SecureRandom.hex(4)}", is_barbell: false)

    post '/exercises', { 'id' => exercise.id.to_s, 'name' => exercise.name, 'dumbbell_count' => '7',
                         '_csrf' => token_for("/exercises/#{exercise.id}/edit") }

    assert_nil exercise.refresh.dumbbell_count
  end
end

