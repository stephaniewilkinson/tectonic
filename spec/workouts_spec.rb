# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# The set-edit picker needs a selectable exercise; the library supplies one.
Tectonic::Exercise.load_library

# The describes below call `sign_in_as_somebody_new`, which used to be a copy of the sign-up
# walk kept in this file under the name `register`. #575 put a confirmation email in the
# middle of that walk and broke every copy of it at once; there is one now, in spec_helper,
# and the note there says why it writes the account rather than signing up for it.

describe 'editing a set' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'saves the new weight from the edit form' do
    sign_in_as_somebody_new
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    # Saving comes back to the form since #631, so the set is opened by its id.
    visit "#{workout}sets/#{DB[:sets].order(:id).last[:id]}/edit"
    fill_in 'Weight', with: '185'
    click_on 'Save'
    assert_includes page.body, '185'
  end
end

describe 'a fresh account' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it "sees none of another account's workouts" do
    sign_in_as_somebody_new
    visit '/workouts'
    assert page.has_no_css?('tbody tr')
  end
end

describe "another account's workout" do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'is out of reach, redirecting a stranger to the index' do
    sign_in_as_somebody_new
    visit '/workouts/new'
    click_on 'Save'
    path = current_path
    Capybara.reset_sessions!
    sign_in_as_somebody_new
    visit path
    assert_equal '/workouts', current_path
  end
end

