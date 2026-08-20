# frozen_string_literal: true

require_relative 'spec_helper'

# These view helpers are pure functions of a set/workout hash, so a bare app
# instance exercises their branches without a request or the database.
describe 'changed_from_plan?' do
  let(:app) { Tectonic.new({}) }

  it 'is false for a set that never had a plan' do
    refute app.changed_from_plan?({ planned_weight: nil, planned_reps: nil, weight: 150, reps: 5 })
  end

  it 'is false when the set was lifted as written' do
    refute app.changed_from_plan?({ planned_weight: 155, planned_reps: 5, weight: 155, reps: 5 })
  end

  it 'is true when the weight or the reps differ from the plan' do
    assert app.changed_from_plan?({ planned_weight: 155, planned_reps: 5, weight: 150, reps: 5 })
    assert app.changed_from_plan?({ planned_weight: 155, planned_reps: 5, weight: 155, reps: 3 })
  end
end

describe 'row_style' do
  let(:app) { Tectonic.new({}) }

  it 'is plain grey until the set is completed' do
    assert_equal 'border-gray-200 bg-white', app.row_style({ is_completed: false })
  end

  it 'is lime when completed as planned' do
    assert_equal 'border-lime-300 bg-lime-50',
                 app.row_style({ is_completed: true, planned_weight: 155, planned_reps: 5, weight: 155, reps: 5 })
  end

  it 'is amber when completed differently from the plan' do
    assert_equal 'border-amber-300 bg-amber-50',
                 app.row_style({ is_completed: true, planned_weight: 155, planned_reps: 5, weight: 150, reps: 5 })
  end
end

describe 'rpe_style' do
  let(:app) { Tectonic.new({}) }

  it 'highlights the chosen rating and leaves the rest plain' do
    assert_equal 'bg-lime-500 text-white', app.rpe_style({ rpe: 8 }, 8)
    assert_equal 'bg-white text-gray-700', app.rpe_style({ rpe: 8 }, 9)
  end
end

describe 'weight_histogram' do
  let(:app) { Tectonic.new({}) }

  it 'is empty for a lift with nothing logged' do
    assert_empty app.weight_histogram([])
  end

  it 'counts the sets at each weight, lightest first' do
    sets = [{ weight: 185, is_warmup: false }, { weight: 135, is_warmup: false }, { weight: 185, is_warmup: false }]

    assert_equal [['135', 1], ['185', 2]], app.weight_histogram(sets)
  end

  # The ramp-up is not the work, and counting it would put the tallest column at the
  # lightest weight on every lift.
  it 'leaves warmups out, down to an empty chart when they are all there is' do
    sets = [{ weight: 45, is_warmup: true }, { weight: 225, is_warmup: false }]

    assert_equal [['225', 1]], app.weight_histogram(sets)
    assert_empty app.weight_histogram([{ weight: 45, is_warmup: true }])
  end
end

describe 'plate_label' do
  let(:app) { Tectonic.new({}) }

  it 'is blank for anything not loaded on a barbell' do
    assert_equal '', app.plate_label({ is_barbell: false, weight: 135 })
  end

  it 'shows the per-side plate math for a loaded bar' do
    assert_equal '1×45', app.plate_label({ is_barbell: true, weight: 135 })
  end
end

