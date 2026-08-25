# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# Colour that belongs to no part of this brand, asserted out of the markup. Two vendor
# accents rode in with the templates they came from and survived for years because
# neither one is loud: Tailwind UI's indigo sits on the two set checkboxes and paints
# nothing at all, since @tailwindcss/forms is not loaded and a native checkbox takes no
# tint from `text-*`; Flowbite's blue only appears while the date field has focus. A
# wrong token breaks no page and fails no other spec -- the indigo is still wrong, and
# it is what a forms plugin would start painting the day one arrives -- so the class is
# asserted against the rendered HTML rather than looked at.
module BrandColour
  def app = Tectonic.app

  def input(id) = last_response.body[/<input\b[^>]*\bid="#{id}"[^>]*>/].to_s

  def classes_of(element) = element[/\sclass="([^"]*)"/, 1].to_s.split

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'), created_on: Time.now)
    get '/login'
    csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post '/login', { login: email, password: 'pw12345678', '_csrf' => csrf }
    DB[:accounts].where(email:).get(:id)
  end
end

describe 'the checkboxes on the new set form' do
  include Rack::Test::Methods
  include BrandColour

  before do
    account_id = sign_in
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    get "/workouts/#{workout_id}/sets/new"
  end

  # The same pair every other checkbox in the app already carries -- see
  # views/exercises/_form.erb and views/authorize.erb.
  it 'tints both boxes lime and rings them lime' do
    %w[is_completed is_warmup].each do |id|
      assert_includes classes_of(input(id)), 'text-lime-500'
      assert_includes classes_of(input(id)), 'focus:ring-lime-500'
    end
  end

  it 'carries no indigo anywhere on the page' do
    refute_includes last_response.body, 'indigo'
  end
end

describe 'the date field on the new workout form' do
  include Rack::Test::Methods
  include BrandColour

  before do
    sign_in
    get '/workouts/new'
  end

  # This one does reach the screen: focus it and the border changes colour, and it was
  # the only field in the app that changed to blue rather than lime.
  it 'rings and borders lime on focus' do
    assert_includes classes_of(input('date')), 'focus:ring-lime-500'
    assert_includes classes_of(input('date')), 'focus:border-lime-500'
    refute_includes last_response.body, 'blue-500'
  end

  # Tailwind's CDN defaults darkMode to media, so these were live on a phone set to dark
  # and drew one grey input in the middle of a page layout.erb keeps at bg-gray-100.
  it 'carries no dark variants for a theme that does not exist' do
    classes_of(input('date')).each { |token| refute_match(/\Adark:/, token) }
  end
end

describe 'the app stylesheet' do
  include Rack::Test::Methods
  include BrandColour

  # `.myteal` styled nothing -- no view named it, and #008080 is in none of the palette.
  # Dead CSS is cheap to keep and expensive to trust, and this one said the brand has a
  # teal in it.
  it 'declares no teal' do
    get '/assets/css/styles.css'

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'teal'
  end
end

