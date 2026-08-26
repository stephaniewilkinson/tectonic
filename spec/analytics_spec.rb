# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# Who gets counted, and who does not. Fathom is a third-party script on every page it is
# on, so where it is absent is worth asserting as firmly as where it is present -- and
# both halves fail silently, one by inflating the numbers and the other by shipping an
# origin to a page that had been keeping its list short.
module Analytics
  SCRIPT = 'cdn.usefathom.com'
  VIEWS = File.expand_path('../views', __dir__)

  def app = Tectonic.app

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'), created_on: Time.now)
    get '/login'
    post '/login', { login: email, password: 'pw12345678',
                     '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
  end
end

describe 'which boots Fathom counts' do
  include Analytics

  # Production alone. Staging reports into the same site id, so a deploy exercised by
  # nobody but us would be indistinguishable from real traffic in the numbers.
  it 'is production, and not staging or anything else' do
    app = Tectonic.new({})

    { 'production' => true, 'staging' => false, 'development' => false, 'test' => false }.each do |env, counted|
      ENV['RACK_ENV'] = env

      assert_equal counted, app.analytics?, "RACK_ENV=#{env}"
    end
  ensure
    ENV['RACK_ENV'] = 'test'
  end
end

describe 'the pages a test run walks' do
  include Rack::Test::Methods
  include Analytics

  # The suite is a few hundred pageviews an hour if this is not gated, and they would be
  # indistinguishable from somebody actually lifting.
  it 'send no pageviews, because this run is not production' do
    sign_in
    ['/', '/start', '/workouts', '/exercises', '/volume', '/equipment'].each do |path|
      get path

      refute_includes last_response.body, Analytics::SCRIPT, "#{path} loaded Fathom outside production"
    end
  end
end

# Read off the template rather than off a rendered page, because the reason this one is
# exempt has nothing to do with the environment: it is the page where a tap hands an API
# client the account, and it names cdn.tailwindcss.com as the only script it will run. A
# rendered assertion would pass in the test environment for the wrong reason and go on
# passing if somebody added the tag here.
describe 'the consent screen' do
  include Analytics

  it 'carries no analytics in its own template, whatever the environment' do
    refute_includes File.read(File.join(Analytics::VIEWS, 'oauth_layout.erb')), Analytics::SCRIPT
  end

  it 'is the exception, so the main layout does carry it' do
    assert_includes File.read(File.join(Analytics::VIEWS, 'layout.erb')), Analytics::SCRIPT
  end
end

