# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# The picker needs a selectable exercise; the library gives us one with no setup.
Tectonic::Exercise.load_library

def sign_up_for_session
  email = "#{SecureRandom.hex}@gmail.com"
  password = SecureRandom.hex
  visit '/'
  click_on 'Sign up'
  fill_in 'email', with: email
  fill_in 'email-confirm', with: email
  fill_in 'password', with: password
  fill_in 'password-confirm', with: password
  click_on 'Sign up'
end

describe 'the session view' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'marks a set done in place with htmx, without reloading' do
    sign_up_for_session
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{workout}session"
    page.execute_script('window.stayed = true')
    click_button 'Done'
    assert page.has_button?('Undo'), 'the set should toggle to Undo in place'
    assert page.evaluate_script('window.stayed === true'), 'the tap should not reload the page'
  end
end

describe 'revising a set in the session' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'records the weight actually lifted and marks the set done' do
    sign_up_for_session
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{workout}session"
    find('summary', text: 'Lifted something else').click
    fill_in 'Weight', with: '145'
    click_button 'Save'
    assert_includes page.body, '145'
    assert page.has_button?('Undo')
  end
end

