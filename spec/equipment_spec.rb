# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/equipment'
require_relative '../lib/tectonic/program_generator'
require 'bcrypt'
require 'securerandom'

# Not `Rack`: that constant is the web server's, and shadowing it at the top level
# breaks Rack::Test::Methods in every other spec the moment the suite loads together.
Gear = Tectonic::Equipment

def account_with(bar: nil, plates: nil)
  id = DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com",
                            password_hash: BCrypt::Password.create('pw12345678'))
  DB[:accounts].where(id:).update(bar_weight: bar) if bar
  plates&.each { |denomination, pairs| DB[:account_plates].insert(account_id: id, denomination:, pairs:) }
  id
end

# An account that has never said what it owns lifts on the rack the app used to assume,
# so nothing changes for anyone who does not care to describe theirs.
describe 'Equipment for an account that has said nothing' do
  it 'is the default bar and plates' do
    equipment = Gear.for_account(account_with)

    assert_equal 45, equipment.bar_weight
    assert_equal 5, equipment.increment
  end
end

# The increment is the whole point: it is the smallest weight change the rack can make,
# and everything the app calculates rounds to it.
describe 'Equipment.increment' do
  it 'is twice the lightest plate, because a bar is loaded on both sides' do
    assert_equal 2, Gear.for_account(account_with(plates: { 45 => 2, 1 => 2 })).increment
    assert_equal 3, Gear.for_account(account_with(plates: { 45 => 2, 1.5 => 2 })).increment
    assert_equal 5, Gear.for_account(account_with(plates: { 45 => 2, 2.5 => 2 })).increment
  end

  it 'rounds a calculated weight to something the rack can load' do
    micro = Gear.for_account(account_with(plates: { 45 => 2, 25 => 2, 1 => 2 }))

    assert_equal 156, micro.round(155.4)
    assert_equal 5, Gear.for_account(account_with(plates: { 2.5 => 2 })).round(4)
  end
end

describe 'Equipment plate math' do
  it 'loads against the account\'s own bar' do
    womens = Gear.for_account(account_with(bar: 35, plates: { 10 => 2 }))

    assert_equal [[10, 1]], womens.per_side(55)
  end

  # The rack holds a number of pairs, not an endless supply, so a weight needing more
  # than it has cannot be loaded and says so rather than being quietly approximated.
  it 'refuses a weight the rack has too few plates for' do
    sparse = Gear.for_account(account_with(plates: { 10 => 1 }))

    assert_equal [[10, 1]], sparse.per_side(65)
    assert_nil sparse.per_side(85)
  end

  it 'reads a micro plate as a real denomination rather than rounding it away' do
    micro = Gear.for_account(account_with(plates: { 1 => 2 }))

    assert_equal [[1, 1]], micro.per_side(47)
  end
end

def week_for(plates)
  account = account_with(plates:)
  program = one_lift_block(account)
  Tectonic::ProgramGenerator.new(program).generate(1)
  Tectonic::Set.where(workout_id: Tectonic::Workout.where(account_id: account).select(:id))
               .exclude(is_warmup: true).order(:id).select_map(:weight)
end

# One block, one week, one day, one lift: the smallest thing that generates a session.
def one_lift_block(account)
  program = Tectonic::Program.create(account_id: account, name: "Block #{SecureRandom.hex(4)}",
                                     start_date: Date.today, preferred_reps: 5)
  week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
  day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
  Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: squat(account).id, position: 0,
                               sets: 3, reps: 5, top_weight: 155, progression: 'linear',
                               is_barbell: true, is_main: true)
  program
end

def squat(account)
  Tectonic::Exercise.create(account_id: account, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
end

# The reason any of this exists: describing your rack has to change what the app
# prescribes, or it is just a form. A generated week is the end of the chain that starts
# at the plates and runs through the warmup ramp, the ascending sets and the rounding.
# 3% apart on a 5 lb rack collapses onto multiples of five; on a 2 lb rack the same
# percentages land on weights the lighter plates can actually make.
describe 'what a finer rack changes about a generated week' do
  it 'writes weights the coarse rack could not express' do
    coarse = week_for({ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2 })
    fine = week_for({ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 1 => 4 })

    assert coarse.all? { |weight| (weight % 5).zero? }, "expected multiples of 5, got #{coarse.inspect}"
    refute_equal coarse, fine
    assert fine.any? { |weight| (weight % 5) != 0 }, "expected a weight off the 5, got #{fine.inspect}"
  end
end

