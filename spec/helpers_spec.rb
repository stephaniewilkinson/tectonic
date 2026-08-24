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

  # Neutral rather than lime: the chosen rating is a value on record, not the completed
  # state the row tint carries and not the action the Done button offers, and it used to
  # wear the same lime-500 as that button.
  it 'highlights the chosen rating and leaves the rest plain' do
    assert_equal 'bg-gray-900 text-white', app.rpe_style({ rpe: 8 }, 8)
    assert_equal 'bg-white text-gray-700', app.rpe_style({ rpe: 8 }, 9)
  end
end

describe 'complete_style' do
  let(:app) { Tectonic.new({}) }

  it 'fills the button that completes a set' do
    assert_equal 'border-sky-800 bg-sky-800 text-white hover:bg-sky-900', app.complete_style({ is_completed: false })
  end

  it 'outlines the button that takes one back' do
    assert_equal 'border-sky-800 bg-white text-sky-900 hover:bg-sky-50', app.complete_style({ is_completed: true })
  end

  # Both carry a border, so Done and Undo occupy the same box and the row does not shift
  # under the thumb as it toggles.
  it 'borders both states so the button does not resize as it toggles' do
    [true, false].each { |done| assert_includes app.complete_style({ is_completed: done }), 'border-sky-800' }
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

  it 'is a dash for a bar with nothing on it' do
    assert_equal '—', app.plate_label({ is_barbell: true, weight: 45 })
  end

  # The case this was written for. 124 is 39.5 a side, which the default rack cannot
  # make, and the answer used to be the empty string -- indistinguishable, on the screen,
  # from a bar that needs nothing.
  it 'names the nearest loadable weight for a weight the rack cannot make' do
    assert_equal 'closest 125: 1×25 1×10 1×5', app.plate_label({ is_barbell: true, weight: 124 })
  end

  it 'says so for a weight lighter than the bar, which no plates reach downwards' do
    assert_equal 'lighter than your 45 lb bar', app.plate_label({ is_barbell: true, weight: 35 })
  end

  # Whatever it says, it says in plain text: the caller escapes it, and a helper that
  # returned markup would have to be found again the day escaping is turned on.
  it 'returns text with no markup in it' do
    [35, 45, 124, 135].each do |weight|
      refute_match(/[<>&]/, app.plate_label({ is_barbell: true, weight: }))
    end
  end
end

