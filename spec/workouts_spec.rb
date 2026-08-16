# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# The set-edit picker needs a selectable exercise; the library supplies one.
Tectonic::Exercise.load_library

def register
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

describe 'editing a set' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'saves the new weight from the edit form' do
    register
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{current_path}edit"
    fill_in 'Weight', with: '185'
    click_on 'Save'
    assert_includes page.body, '185'
  end
end

describe 'a fresh account' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it "sees none of another account's workouts" do
    register
    visit '/workouts'
    assert page.has_no_css?('tbody tr')
  end
end

