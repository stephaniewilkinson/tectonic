# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# Seed the built-in library once, the way `rake library:exercises` does on deploy.
Tectonic::Exercise.load_library

def sign_up
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

def add_exercise(name)
  visit '/exercises'
  click_on 'Add a new exercise'
  fill_in 'name', with: name
  click_on 'Save'
end

describe 'the exercise library' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'loads idempotently, with no duplicate rows on a second run' do
    created, skipped = Tectonic::Exercise.load_library
    assert_equal 0, created
    assert_equal Tectonic::Exercise::LIBRARY.length, skipped
    assert_equal Tectonic::Exercise::LIBRARY.length, Tectonic::Exercise.where(account_id: nil).count
  end
end

describe 'a new account' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'sees the library and can add its own alongside it' do
    sign_up
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    add_exercise 'My Garage Special'
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    assert_includes page.body, 'My Garage Special'
  end
end

describe 'a private exercise' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'is invisible to and uneditable by another account' do
    sign_up
    add_exercise 'Private Move A'
    path = current_path
    Capybara.reset_sessions!
    sign_up
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    refute_includes page.body, 'Private Move A'
    visit path
    refute_includes page.body, 'Private Move A'
    visit "#{path}edit"
    refute_includes page.body, 'Private Move A'
  end
end

describe 'a library exercise' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'shows as read-only and refuses a direct edit' do
    sign_up
    visit '/exercises'
    click_on 'Back Squat'
    assert page.has_no_link?('Edit')
    assert_includes page.body, 'Built-in'
    visit "#{current_path}/edit"
    refute_includes page.current_path, 'edit'
  end
end

