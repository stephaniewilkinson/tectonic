# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# #341: the session screen refreshes itself over htmx every fifteen seconds, and a
# signed-out answer to that refresh used to be the login page itself -- Rodauth
# redirects, the browser follows the redirect inside the background fetch, and htmx
# receives sign-in markup with a 200 on it and splices it into the middle of the
# workout. What must hold instead: a request that says it is htmx gets the header
# htmx reads before it considers swapping, and a plain browser request keeps the
# redirect it always had.
module HtmxLogin
  def app
    Tectonic.app
  end

  def sign_up
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'))
    get '/login'
    post '/login', { login: email, password: 'pw12345678',
                     '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
  end
end

describe 'a request that demands a login' do
  include Rack::Test::Methods
  include HtmxLogin

  it 'sends a signed-out htmx request to the login screen whole, not as markup' do
    get '/workouts', {}, 'HTTP_HX_REQUEST' => 'true'

    assert_equal 401, last_response.status
    assert_equal '/login', last_response.headers['HX-Redirect']
    refute_includes last_response.body.to_s, 'Sign in'
  end

  it 'keeps the redirect a plain browser request always had' do
    get '/workouts'

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], '/login'
    assert_nil last_response.headers['HX-Redirect']
  end

  it 'stays out of the way of a signed-in htmx request' do
    sign_up
    get '/workouts', {}, 'HTTP_HX_REQUEST' => 'true'

    assert_equal 200, last_response.status
    assert_nil last_response.headers['HX-Redirect']
  end
end

