# frozen_string_literal: true

require_relative 'spec_helper'

describe Tectonic do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include Rack::Test::Methods

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

  it 'lets user log in and look at a shelf' do
    visit '/'
    visit '/workouts'
    fill_in 'Email address', with: 'myemail@gmail.com'
    fill_in 'Password', with: 'password'
    click_on 'Sign in'
  end
end
