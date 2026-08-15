# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

describe Tectonic do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include Rack::Test::Methods

  password = SecureRandom.hex
  email = "#{SecureRandom.hex}@gmail.com"

  let :app do
    Tectonic
  end

  it 'responds to root' do
    visit '/'
    assert current_path == '/welcome'
  end

  it 'responds to /about' do
    get '/about'
    assert last_response.ok?
    assert_includes last_response.body, 'stephanie'
  end

  it 'lets new user sign up' do
    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: email
    fill_in 'email-confirm', with: email
    fill_in 'password', with: password
    fill_in 'password-confirm', with: password
    click_on 'Sign up'
    assert_includes page.body, 'Start a new workout'
    click_on 'exit'
    assert_includes page.body, 'Log out'
    click_on 'Log out'
  end

  it 'deletes a workout in place with htmx' do
    pw = SecureRandom.hex
    mail = "#{SecureRandom.hex}@gmail.com"

    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: mail
    fill_in 'email-confirm', with: mail
    fill_in 'password', with: pw
    fill_in 'password-confirm', with: pw
    click_on 'Sign up'

    visit '/workouts/new'
    click_on 'Save'

    visit '/workouts'
    assert_equal 1, all('tbody tr').count

    # A full page load clears this; an htmx row swap leaves it in place, which is
    # what tells the two apart and proves the delete never navigated.
    page.execute_script('window.stayedOnPage = true')
    within(first('tbody tr')) { click_button 'Delete' }

    assert has_no_selector?('tbody tr'), 'the deleted workout should leave the list'
    assert page.evaluate_script('window.stayedOnPage === true'), 'delete should not reload the page'
    assert_equal '/workouts', current_path
  end
end

