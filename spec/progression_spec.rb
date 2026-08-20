# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/progression'

# A working set as the generator wrote it and the session left it. Lifting one as written
# only flips is_completed, so weight and reps default to what was planned.
def set(planned_weight: 155, planned_reps: 5, weight: nil, reps: nil, is_completed: true)
  { planned_weight:, planned_reps:, weight: weight || planned_weight,
    reps: reps || planned_reps, is_completed: }
end

describe 'Progression.next_top_weight' do
  it 'adds five pounds to a week that was lifted as written' do
    assert_equal 160, Tectonic::Progression.next_top_weight(155, [set, set, set])
  end

  it 'takes ten off a week whose sets were left uncompleted' do
    assert_equal 145, Tectonic::Progression.next_top_weight(155, [set, set, set(is_completed: false)])
  end

  it 'takes ten off a week that was lifted under the prescription' do
    assert_equal 145, Tectonic::Progression.next_top_weight(155, [set, set(reps: 3)])
    assert_equal 145, Tectonic::Progression.next_top_weight(155, [set, set(weight: 145)])
  end

  # Absence of proof, not proof of weakness: three skipped weeks would otherwise compound
  # into a prescription far under what the lifter can do, inferred from days with no bar.
  it 'repeats a week nothing was lifted in rather than reading it as a failure' do
    missed = [set(is_completed: false), set(is_completed: false)]
    assert_equal 155, Tectonic::Progression.next_top_weight(155, missed)
    assert_equal 155, Tectonic::Progression.next_top_weight(155, [])
  end

  it 'counts lifting more than was asked as meeting the prescription' do
    assert_equal 160, Tectonic::Progression.next_top_weight(155, [set(weight: 165), set(reps: 6)])
  end

  it 'stops at a loadable floor rather than working down to nothing' do
    assert_equal 5, Tectonic::Progression.next_top_weight(10, [set(planned_weight: 10, is_completed: false), set])
  end
end

describe 'Progression.deloaded' do
  it 'takes a tenth off and lands on something the bar can make' do
    assert_equal 140, Tectonic::Progression.deloaded(155) # 139.5, rounded to the 5
    assert_equal 180, Tectonic::Progression.deloaded(200)
  end
end

