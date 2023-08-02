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
end
