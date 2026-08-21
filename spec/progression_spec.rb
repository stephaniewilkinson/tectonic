# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/progression'

Progression = Tectonic::Progression

# A working set as the generator wrote it and the session left it. Lifting one as written
# only flips is_completed, so weight and reps default to what was planned.
def set(planned_weight: 155, planned_reps: 5, weight: nil, reps: nil, is_completed: true)
  { planned_weight:, planned_reps:, weight: weight || planned_weight,
    reps: reps || planned_reps, is_completed: }
end

# Outcomes are most recent first, so a list reads as a history running backwards from the
# week about to be prescribed.
describe 'Progression.next_top_weight' do
  it 'adds an increment to a week that was lifted as written' do
    assert_equal 160, Progression.next_top_weight(155, [:met])
    assert_equal 160, Progression.next_top_weight(155, %i[met met met])
  end

  # One missed rep is not a stall. Sleep, food and stress move day-to-day performance by
  # more than a rep, so the same weight is asked again under different conditions.
  it 'holds the weight the first time a week falls short' do
    assert_equal 155, Progression.next_top_weight(155, %i[short met])
  end

  it 'backs off only once a second attempt has fallen short too' do
    assert_equal 150, Progression.next_top_weight(155, %i[short short])
  end

  # A good week answers the question the first failure asked, so the count starts again
  # rather than carrying a strike forward indefinitely.
  it 'lets a good week clear the count between two bad ones' do
    assert_equal 155, Progression.next_top_weight(155, %i[short met short])
  end

  # Absence of proof, not proof of weakness: three skipped weeks would otherwise compound
  # into a prescription far under what the lifter can do, inferred from days with no bar.
  it 'repeats a week nothing was lifted in rather than reading it as a failure' do
    assert_equal 155, Progression.next_top_weight(155, [:missed])
    assert_equal 155, Progression.next_top_weight(155, [])
  end
end

# The edges: an untrained week between two attempts, a floor to back off towards, and the
# increment itself, which is a fact about the rack rather than about the rule.
describe 'Progression.next_top_weight at its edges' do
  # A week nobody trained is not an answer in either direction, so it neither breaks a run
  # of failures nor counts towards one.
  it 'looks past an untrained week to the attempts either side of it' do
    assert_equal 150, Progression.next_top_weight(155, %i[short missed short])
  end

  it 'stops at a loadable floor rather than working down to nothing' do
    assert_equal 5, Progression.next_top_weight(10, %i[short short])
    assert_equal 5, Progression.next_top_weight(5, %i[short short])
  end

  # The increment is the smallest jump the bar can make, which is a fact about the rack
  # rather than about the rule -- see #64. Passing it in is what lets micro plates change
  # the programme without changing this code.
  it 'steps by whatever increment it is given' do
    assert_equal 157, Progression.next_top_weight(155, [:met], increment: 2)
    assert_equal 153, Progression.next_top_weight(155, %i[short short], increment: 2)
  end
end

describe 'Progression.outcome' do
  it 'reads a week lifted as written as having met the prescription' do
    assert_equal :met, Progression.outcome([set, set, set])
  end

  it 'reads lifting more than was asked as meeting it too' do
    assert_equal :met, Progression.outcome([set(weight: 165), set(reps: 6)])
  end

  it 'reads a session left uncompleted as short rather than missed' do
    assert_equal :short, Progression.outcome([set, set(is_completed: false)])
  end

  it 'reads lifting under the prescription as short' do
    assert_equal :short, Progression.outcome([set, set(reps: 3)])
    assert_equal :short, Progression.outcome([set, set(weight: 145)])
  end

  # Nothing completed at all is a week that did not happen, which the rules hold on.
  it 'reads a week with nothing completed as missed' do
    assert_equal :missed, Progression.outcome([set(is_completed: false), set(is_completed: false)])
  end
end

describe 'Progression.deloaded' do
  it 'takes a tenth off and lands on something the bar can make' do
    assert_equal 140, Progression.deloaded(155) # 139.5, rounded to the 5
    assert_equal 180, Progression.deloaded(200)
  end
end

