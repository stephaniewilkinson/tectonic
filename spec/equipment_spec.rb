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
end

# What `round` promised in its name and its comment and did not do. It put a weight on a
# multiple of the increment, and this spec used to assert two weights that proved it:
# 156 on a rack of 45s, 25s and 1s, and 5 on a bar weighing 45. `per_side` answers nil to
# both -- the spec was pinning the bug rather than the behaviour, which is how it survived
# being read.
describe 'Equipment.loadable' do
  # The guarantee, stated as the plate math and the rounding agreeing. Everything else in
  # this describe is a case of it; this is the property.
  it 'always lands on a weight the plate math can express' do
    racks = [{ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 }, { 45 => 2, 25 => 2, 1 => 2 },
             { 10 => 1 }, { 45 => 1, 2.5 => 2 }]
    racks.each do |plates|
      rack = Gear.for_account(account_with(plates:))
      (40..400).step(7) do |asked| # 7 so the walk lands off every plate grid these racks have
        refute_nil rack.per_side(rack.loadable(asked)), "#{plates.keys.inspect} cannot load #{asked}"
      end
    end
  end

  # The weight from the screenshot on #140. One pair of 1 lb plates makes the increment 2,
  # 124 is a multiple of 2, and 124 needs two pairs of 1s -- so the old rounding wrote a
  # prescription the plate math could only answer nil to.
  it 'refuses to write the weight #140 was reported for' do
    rack = Gear.for_account(account_with(plates: { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 }))

    assert_equal 125, rack.loadable(124)
    assert_nil rack.per_side(124)
    refute_nil rack.per_side(125)
  end

  # The other direction, which is the half nobody had noticed. 47 is one 1 lb plate a side
  # and this rack loads it, but 47 is not a multiple of the increment, so no amount of
  # rounding to the increment could ever have produced it. Buying micro plates to get finer
  # jumps was making the prescriptions coarser than the rack.
  it 'can write a loadable weight that is not a multiple of the increment' do
    rack = Gear.for_account(account_with(plates: { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 }))

    assert_equal 2, rack.increment
    refute_predicate 47 % rack.increment, :zero?
    assert_equal 47, rack.loadable(47)
  end
end

# The answers that are not a weight off the middle of the rack, each of which the old
# rounding got wrong in its own way or was never asked.
describe 'Equipment.loadable at the edges' do
  # Nothing below the bar is loadable, and the bar is the lightest thing that is. The old
  # rounding answered 5 here, which is a number nobody can put on a 45 lb bar.
  it 'answers the bar for anything lighter than it' do
    rack = Gear.for_account(account_with(plates: { 2.5 => 2 }))

    assert_equal 45, rack.loadable(4)
    assert_equal 45, rack.loadable(44.9)
  end

  # A machine stack or a dumbbell is not loaded off this rack, so putting its weight
  # through barbell plate math would be a new wrong answer in place of the old one.
  #
  # It used to take the bar's own increment, and #259 is why it no longer does: the bar's
  # increment is a fact about the plates an account owns, and buying a pair of 1 lb plates
  # took it to 2 and started prescribing 26 lb dumbbells. The reasoning above is unchanged
  # -- the plate enumeration is still not consulted -- but the number it falls back to is
  # now the dumbbell's, not the bar's.
  it 'holds a lift that is not on a barbell to its own increment rather than the bar' do
    rack = Gear.for_account(account_with(plates: { 45 => 2, 25 => 2, 1 => 2 }))

    assert_equal 2, rack.increment
    assert_equal 5, rack.increment_for(is_barbell: false)
    assert_equal 200, rack.loadable(200, is_barbell: false)
    assert_equal 5, rack.loadable(4, is_barbell: false)
  end

  # write_flat passes the weight of an unweighted lift straight through, and that is nil.
  it 'passes nil through rather than inventing a load for a bodyweight lift' do
    assert_nil Gear.for_account(account_with).loadable(nil)
  end

  # A week's generation rounds a few dozen times and every one of them would otherwise
  # re-enumerate the same rack, which is the cost #140 said to measure before committing.
  it 'works the rack out once and keeps it' do
    rack = Gear.for_account(account_with(plates: { 45 => 2, 25 => 2, 10 => 2 }))

    assert_same rack.loadable_totals, rack.loadable_totals
    assert_equal rack.loadable_totals.sort, rack.loadable_totals
    assert_equal 45, rack.loadable_totals.first
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
  Tectonic::WorkoutSet.where(workout_id: Tectonic::Workout.where(account_id: account).select(:id))
                      .exclude(is_warmup: true).order(:id).select_map(:weight)
end

# One block, one week, one day, one lift: the smallest thing that generates a session.
def one_lift_block(account, top: 155, barbell: true)
  program = Tectonic::Program.create(account_id: account, name: "Block #{SecureRandom.hex(4)}",
                                     start_date: Date.today, preferred_reps: 5)
  week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
  day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
  Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: squat(account).id, position: 0,
                               sets: 3, reps: 5, top_weight: top, progression: 'linear',
                               is_barbell: barbell, is_main: true)
  program
end

# Every weight a generated week writes, warmups included, with the rack that wrote them.
# The ramp is the half that matters most here: #140 was reported against a warmup step,
# so a check that reads only the working sets would have missed the thing it is named for.
def generated_week_on(plates, top: 155, barbell: true)
  account = account_with(plates:)
  Tectonic::ProgramGenerator.new(one_lift_block(account, top:, barbell:)).generate(1)
  weights = Tectonic::WorkoutSet.where(workout_id: Tectonic::Workout.where(account_id: account).select(:id))
                                .order(:id).select_map(:weight).compact
  [weights, Gear.for_account(account)]
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

# The guarantee #140 asked for, stated where it matters: not that one rounding is right in
# isolation, but that nothing reaches a set row the plate math cannot express. Before this,
# the generator and `per_side` were answering two different questions and only met on the
# session screen, where the disagreement showed up as a row with no plate math on it.
describe 'every weight a generated week writes' do
  it 'is one the rack can actually load, warmups included' do
    [{ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 },
     { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 1 => 4 },
     { 45 => 2, 25 => 2, 1 => 2 },
     { 45 => 1, 2.5 => 2 }].each do |plates|
      weights, rack = generated_week_on(plates)

      refute_empty weights, "#{plates.keys.inspect} generated no sets to check"
      unloadable = weights.uniq.reject { |weight| rack.per_side(weight) }

      assert_empty unloadable, "#{plates.keys.inspect} cannot load #{unloadable.inspect}"
    end
  end

  # The report itself. A squat written to 165 on a rack holding one pair of 1 lb plates
  # produced a ramp of 45, 100, 124, 144 -- and 124 is 39.5 a side, which wants two pairs
  # of 1s. It is asserted by name as well as by the property above, because the property
  # would go on passing if the ramp quietly stopped being generated at all.
  it 'no longer writes the 124 the issue was reported for' do
    weights, rack = generated_week_on({ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 }, top: 165)

    assert_includes weights, 45, 'the ramp should still open at the bar'
    assert_operator weights.length, :>=, 4, 'the ramp should still be a ramp'
    refute_includes weights, 124
    assert_empty(weights.uniq.reject { |weight| rack.per_side(weight) })
  end
end

# The deliberate exception, pinned because it looks exactly like the bug it is not. A
# machine stack is not loaded off this rack, so its weight is not held to what the rack
# can build -- and the session view knows, because it draws no plate math for a set that
# is not on a barbell. A sweep that read every generated weight without asking this
# question would report the machine as a failure, which is what it did while this was
# being written.
describe 'a generated weight that is not on the bar' do
  # Asserted as "on its own grid" rather than as "off the barbell's", which is what it
  # said before #259. That worked while the fallback was the bar's increment and a fine
  # rack could produce an odd number the bar could not build; now the fallback is fives,
  # and a multiple of five is usually loadable on a bar too, so the old assertion tested
  # a coincidence. The claim worth making is the positive one.
  it 'is held to the dumbbell grid rather than to the rack' do
    weights, rack = generated_week_on({ 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 1 },
                                      top: 135, barbell: false)
    step = rack.increment_for(is_barbell: false)

    refute_empty weights
    assert weights.all? { |weight| (weight % step).zero? },
           "a machine should step by #{step}, got #{weights.inspect}"
  end
end

