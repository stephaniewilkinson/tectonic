# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'program_generator_spec' # reuses build_program; idempotent require
require_relative '../lib/tectonic/program_generator'
require 'date'

# The generator end of progression: a block of several weeks, each generated only after the
# one before it has been lifted (or not), which is the order a lifter actually meets them
# in. build_program writes 4x5 to 155 on the bar into every week.
module Progressing
  # build_program writes 4x5 to 155 into a program that prefers threes, and SetScheme
  # converts that to 4x3 at 165 before it is ever written down. That conversion is a
  # separate behaviour with a spec of its own, and it makes every number here one the
  # reader has to derive, so these blocks drop the preference and a lift written at 155 is
  # generated at 155. The one test that is about the conversion keeps it.
  def block(weeks:)
    build_program(weeks:).tap { |program| program.update(preferred_reps: nil) }
  end

  # Generates a week and hands back its top working weight, which is what the next week's
  # rule is read against.
  def generate(program, number)
    workout = Tectonic::ProgramGenerator.new(program).generate(number).first
    [workout, top_planned(workout)]
  end

  def top_planned(workout)
    Tectonic::Set.where(workout_id: workout.id, is_warmup: false).map(:planned_weight).max
  end

  def working_sets(workout)
    Tectonic::Set.where(workout_id: workout.id, is_warmup: false).all
  end

  # Lifts every working set exactly as written, which is the week that earns an increase.
  def lift_as_written(workout)
    working_sets(workout).each { |set| set.update(is_completed: true) }
  end

  # Lifts the week but leaves its last set undone, which is the week that does not.
  def fall_short(workout)
    sets = working_sets(workout)
    sets[0..-2].each { |set| set.update(is_completed: true) }
  end

  # Marks a week's deload flag, which is authored on the week rather than on its lifts.
  def deload(program, number)
    program.week(number).update(is_deload: true)
  end
end

describe 'a block that climbs off its own results' do
  include Progressing

  it 'generates week one at exactly the load it was written with' do
    program = block(weeks: 3)
    assert_equal 155, generate(program, 1).last
  end

  it 'adds five pounds after a week lifted as written' do
    program = block(weeks: 3)
    workout, = generate(program, 1)
    lift_as_written(workout)

    assert_equal 160, generate(program, 2).last
  end

  it 'keeps climbing week on week, each week read off the one before it' do
    program = block(weeks: 3)
    tops = (1..3).map do |number|
      workout, top = generate(program, number)
      lift_as_written(workout)
      top
    end

    assert_equal [155, 160, 165], tops
  end
end

describe 'a block that responds to a week that went badly' do
  include Progressing

  # One bad week asks the same question again rather than answering it: the weight holds,
  # and only a second failure at it reads as a stall worth backing off from.
  it 'holds the load after a single week whose working sets went uncompleted' do
    program = block(weeks: 3)
    workout, = generate(program, 1)
    fall_short(workout)

    assert_equal 155, generate(program, 2).last
  end

  it 'holds the load after a single week lifted under what it asked for' do
    program = block(weeks: 3)
    workout, = generate(program, 1)
    working_sets(workout).each { |set| set.update(is_completed: true, reps: set.planned_reps - 2) }

    assert_equal 155, generate(program, 2).last
  end
end

# Two failures running is the signal the rule waits for before it moves the weight down.
describe 'a block that backs off after a genuine stall' do
  include Progressing

  it 'backs off once a second attempt has fallen short too' do
    program = block(weeks: 3)
    first, = generate(program, 1)
    fall_short(first)
    second, = generate(program, 2)
    fall_short(second)

    assert_equal 150, generate(program, 3).last
  end

  # A week nobody trained says nothing about how strong the lifter is, so it moves nothing.
  it 'repeats the load after a week that was never trained at all' do
    program = block(weeks: 2)
    generate(program, 1)

    assert_equal 155, generate(program, 2).last
  end
end

describe 'a deload week' do
  include Progressing

  it 'takes a tenth off the load the week would otherwise have been given' do
    program = block(weeks: 2)
    workout, = generate(program, 1)
    lift_as_written(workout)
    deload(program, 2)

    assert_equal 145, generate(program, 2).last # 160 due, less a tenth, rounded to the 5
  end

  # Progressing from a deload would carry its reduction into every week after it, so a
  # block would ratchet down a little each time it recovered. The week after resumes the
  # climb from the last week that was actually working weight.
  it 'is not what the week after it progresses from' do
    program = block(weeks: 3)
    first, = generate(program, 1)
    lift_as_written(first)
    deload(program, 2)
    second, = generate(program, 2)
    lift_as_written(second)

    assert_equal 160, generate(program, 3).last # week one's 155 plus five, not the deload's 145 plus five
  end
end

# The load a lift is written at and the load its sets are written at are not the same
# number whenever the program prefers a different rep count, and the step belongs to the
# first of them.
describe 'progression under the rep conversion' do
  include Progressing

  it 'steps the load the lift was written in, not the one the conversion produced' do
    program = build_program(weeks: 2) # prefers threes: 4x5 to 155 is generated as 4x3 to 165
    workout, top = generate(program, 1)
    assert_equal 165, top
    lift_as_written(workout)

    # 155 + 5 = 160, converted to threes. Stepping the converted 165 and converting that
    # again would ask for 180 in the second week of a block meant to add five pounds.
    assert_equal 170, generate(program, 2).last
  end
end

describe 'a lift written to hold still' do
  include Progressing

  it 'generates the same load every week however the lifting went' do
    program = block(weeks: 2)
    Tectonic::ProgramLift.where(program_day_id: program.week(2).program_days.map(&:id))
                         .update(progression: 'fixed')
    workout, = generate(program, 1)
    lift_as_written(workout)

    assert_equal 155, generate(program, 2).last
  end
end

