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
end
