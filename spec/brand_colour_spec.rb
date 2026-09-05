# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# Colour that belongs to no part of this brand, asserted out of the markup. Two vendor
# accents rode in with the templates they came from and survived for years because
# neither one is loud: Tailwind UI's indigo sat on the two set checkboxes and painted
# nothing at all, since @tailwindcss/forms is not loaded and a native checkbox takes no
# tint from `text-*`; Flowbite's blue only appeared while the date field had focus. A
# wrong token breaks no page and fails no other spec, which is how the indigo lasted,
# so the classes are asserted against the rendered HTML rather than looked at. The
# `accent-*` assertions are the ones that stand for something on screen; the `text-*`
# and `focus:ring-*` ones only matter if a forms plugin ever arrives, and they are
# pinned so that arrival does not reopen this.
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

  # accent-lime-500 is the one that reaches the screen: without it a native checkbox
  # draws in the browser's default blue whatever `text-*` says.
  it 'tints both boxes lime and rings them lime' do
    %w[is_completed is_warmup].each do |id|
      assert_includes classes_of(input(id)), 'accent-lime-500'
      assert_includes classes_of(input(id)), 'text-lime-500'
      assert_includes classes_of(input(id)), 'focus:ring-lime-500'
    end
  end

  it 'carries no indigo anywhere on the page' do
    refute_includes last_response.body, 'indigo'
  end
end

describe 'the checkbox on the exercise form' do
  include Rack::Test::Methods
  include BrandColour

  before do
    sign_in
    get '/exercises/new'
  end

  # This one was already lime and still drew blue, for want of the accent utility.
  it 'accents lime like the set form does' do
    assert_includes classes_of(input('is_barbell')), 'accent-lime-500'
    assert_includes classes_of(input('is_barbell')), 'text-lime-500'
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
  #
  # sky-800 since #333, which took every focus ring off lime -- lime-500 is 1.98:1 on white
  # against the 3:1 an indicator is asked for. This field does not go through field_style,
  # so it kept the old colour after that change and was once again the only one that
  # differed; #368 brought it back into line. What the spec is really holding is that it
  # matches the rest, so it now names the colour the rest of them use.
  it 'rings and borders like every other field on focus' do
    assert_includes classes_of(input('date')), 'focus:ring-sky-800'
    assert_includes classes_of(input('date')), 'focus:border-sky-800'
    refute_includes last_response.body, 'blue-500'
  end

  # Tailwind's CDN defaults darkMode to media, so these were live on a phone set to dark
  # and drew one grey input in the middle of a page layout.erb keeps at bg-gray-100.
  it 'carries no dark variants for a theme that does not exist' do
    tokens = classes_of(input('date'))

    # An empty list would walk this loop zero times and pass, which is the one way a
    # renamed id could quietly retire the assertion.
    refute_empty tokens
    tokens.each { |token| refute_match(/\Adark:/, token) }
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

