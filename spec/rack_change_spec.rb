# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/rack_change'
require 'securerandom'
require 'date'

# Changing the rack reaches the sessions the rack already wrote. #439.
#
# The plate math was not the bug, which took reproducing to establish. #369 taught the
# generator to enumerate a dumbbell the way #140 taught it to enumerate a bar, and against the
# reporting account's real inventory -- a 4 lb handle with pairs of 10, 5 and 2.5 --
# `Equipment#dumbbell_totals` comes out as exactly [4, 9, 14 ... 79]. Every loadable dumbbell
# ends in 4 or 9, `loadable(45)` is 44, and that is the issue's own arithmetic.
#
# What was wrong is that the answer never reached the sessions already written. In production
# the same movement at the same prescribed top weight of 45 sits in the block as **44 on
# 2026-09-21 and 45 on 2026-09-28** -- nothing about the plan differs, only which of them was
# generated after the inventory was filled in.
module RackChanging
  # A dumbbell movement prescribed at a weight no 4 lb handle can build.
  def a_block_of_dumbbells(account_id, top_weight: 45, on: Date.today + 7)
    exercise = Tectonic::Exercise.create(account_id:, name: "DB Row #{SecureRandom.hex(4)}", is_barbell: false)
    program = Tectonic::Program.create(account_id:, name: 'Block', start_date: on, is_ascending: true)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: on.wday)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 8, top_weight:, progression: 'linear',
                                 is_main: false, is_barbell: false)
    Tectonic::ProgramGenerator.new(program).generate(1)
    [program, day]
  end

  # The reporting account's rack, exactly: a 4 lb handle with pairs of 10, 5 and 2.5.
  def describe_the_dumbbells(account_id)
    Tectonic::Equipment.replace(account_id, bar_weight: 45, plates: nil,
                                            dumbbell_handle_weight: '4',
                                            dumbbell_plates: { '10' => '2', '5' => '2', '2.5' => '3' })
  end

  def weights_on(day)
    workout = Tectonic::Workout.where(program_day_id: day.id).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }
  end
end

# The arithmetic the issue turns on, pinned directly. If this ever stops being true the fix
# below is solving a problem that has moved.
describe 'what a four pound handle can actually build' do
  include RackChanging

  before do
    @rack = Tectonic::Equipment.new(bar_weight: 45, pairs: { 45 => 1, 25 => 1, 10 => 1, 5 => 2, 2.5 => 2 },
                                    dumbbell_handle_weight: 4,
                                    dumbbell_pairs: { 10 => 2, 5 => 2, 2.5 => 3 })
  end

  # "Every loadable dumbbell weight ends in 4 or 9 -- never 0 or 5", which is the issue's own
  # observation and the reason 35, 40 and 45 were all impossible.
  it 'never lands on a zero or a five' do
    refute_empty @rack.dumbbell_totals
    @rack.dumbbell_totals.each { |total| assert_includes [4, 9], total % 10, "#{total} is not loadable" }
  end

  it 'answers a prescription of 45 with the 44 underneath it' do
    assert_equal 44, @rack.loadable(45, is_barbell: false)
  end
end

# The bug itself: a session generated before the rack was described keeps the weight it was
# given then, and nothing ever revisits it.
describe 'a session generated before the rack was described' do
  include Rack::Test::Methods
  include RouteOwnership
  include RackChanging

  before do
    @account_id = login
    _program, @day = a_block_of_dumbbells(@account_id)
  end

  it 'starts out on a weight the new rack cannot load' do
    describe_the_dumbbells(@account_id)

    assert_equal [35, 40, 45], weights_on(@day), 'the stale session should be untouched until rerounded'
  end

  it 'is brought onto a loadable weight when the rack changes' do
    describe_the_dumbbells(@account_id)

    Tectonic::RackChange.reround(@account_id)

    assert_equal [34, 39, 44], weights_on(@day)
  end

  it 'reports how many sessions it moved' do
    describe_the_dumbbells(@account_id)

    assert_equal 1, Tectonic::RackChange.reround(@account_id)
  end

  # The count is of sessions that changed, not of sessions rewritten -- refresh rewrites
  # unconditionally, so without this a save that altered nothing would still announce that it
  # had rewritten every session in the block.
  it 'reports nothing the second time, because nothing moves twice' do
    describe_the_dumbbells(@account_id)
    Tectonic::RackChange.reround(@account_id)

    assert_equal 0, Tectonic::RackChange.reround(@account_id)
  end
end

# What re-rounding must not touch, which is the same guarantee #407 earned and this inherits
# by going through the same `refresh`.
describe 'what a rack change must not rewrite' do
  include Rack::Test::Methods
  include RouteOwnership
  include RackChanging

  it 'leaves a set that was already lifted exactly as it was' do
    account_id = login
    _program, day = a_block_of_dumbbells(account_id)
    workout = Tectonic::Workout.where(program_day_id: day.id).first
    lifted = Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).order(:id).first
    lifted.update(is_completed: true, completed_at: Time.now)
    describe_the_dumbbells(account_id)

    Tectonic::RackChange.reround(account_id)

    assert_equal 35, Tectonic::Plates.numeric(lifted.refresh.weight)
    assert lifted.refresh.is_completed
  end

  # A past session says what the plan was on the day. Re-rounding it would be the app
  # revising history to match equipment bought afterwards.
  it 'does not reach back into a session that has already been and gone' do
    account_id = login
    _program, day = a_block_of_dumbbells(account_id, on: Date.today - 14)
    describe_the_dumbbells(account_id)

    Tectonic::RackChange.reround(account_id)

    assert_equal [35, 40, 45], weights_on(day)
  end
end

# The ordinary account-scoping guarantee, said out loud because this walks workouts directly
# rather than going through one of the context-scoped datasets that would enforce it for free.
describe 'whose sessions a rack change reaches' do
  include Rack::Test::Methods
  include RouteOwnership
  include RackChanging

  it 'leaves another account alone' do
    mine = login
    theirs = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    _program, their_day = a_block_of_dumbbells(theirs)
    describe_the_dumbbells(mine)
    describe_the_dumbbells(theirs)

    Tectonic::RackChange.reround(mine)

    assert_equal [35, 40, 45], weights_on(their_day)
  end
end

# And the whole thing through the page a lifter actually uses, since the wiring is where this
# would otherwise be silently missing.
describe 'saving the equipment form' do
  include Rack::Test::Methods
  include RouteOwnership
  include RackChanging

  before do
    @account_id = login
    _program, @day = a_block_of_dumbbells(@account_id)
    post '/settings', { 'bar_weight' => '45', 'dumbbell_handle_weight' => '4',
                        'dumbbell_plates' => { '10' => '2', '5' => '2', '2.5' => '3' },
                        # token_for_form and not token_for: this page carries three forms --
                        # zone, week and equipment -- each with a token Roda has bound to its
                        # own action, and token_for takes the first, which is the zone form's.
                        # The post comes back 403 and the assertions below would then be
                        # describing a request that never happened.
                        '_csrf' => token_for_form('/settings', '/settings') }
    follow_redirect!
  end

  it 'rerounds my upcoming sessions' do
    assert_equal [34, 39, 44], weights_on(@day)
  end

  it 'says what it did rather than moving the numbers silently' do
    assert_includes last_response.body.gsub(/\s+/, ' '), '1 upcoming session was'
  end
end

