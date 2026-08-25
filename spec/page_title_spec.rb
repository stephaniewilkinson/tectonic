# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# What a page calls itself. It is the most repeated element in the app and it had no rule:
# five sizes, four elements, and two pages where the title was a bare line of text above a
# form. The record of a workout opened on a 48px h3 -- the largest type a signed-in
# account ever saw, and a heading level with no h1 or h2 above it -- while /workouts,
# /exercises and the set list titled themselves at 16px, the size of their own body copy.
#
# The rule is one h1 at text-3xl, which was already the plurality. Nothing breaks when it
# is broken again: every page renders, every link works, and the only symptom is a title
# that is twice the size of the one before it, which is why it is asserted here rather
# than noticed.
module PageTitle
  # Every Tailwind size utility, so a title that keeps text-3xl and adds a second size is
  # caught as well as one that names the wrong size outright.
  SIZES = /\Atext-(?:xs|sm|base|lg|\d?xl)\z/

  def app = Tectonic.app

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'), created_on: Time.now)
    get '/login'
    post '/login', { login: email, password: 'pw12345678',
                     '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    DB[:accounts].where(email:).get(:id)
  end

  # The first heading on the page is its title: the nav above it is links and holds none.
  # An h3 as a page title is a skipped level as well as a size, which is a real reading for
  # somebody moving through a page by heading, so the level is asserted before the size.
  def title_of(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    tag = last_response.body[/<h[1-6]\b[^>]*>/]

    refute_nil tag, "#{path} has no heading to be its title"
    assert_equal '1', tag[/<h(\d)/, 1], "#{path} titles itself with #{tag[/<h\d/]} rather than an h1"
    tag
  end

  def assert_page_title(path)
    classes = title_of(path)[/\sclass="([^"]*)"/, 1].to_s.split

    assert_equal ['text-3xl'], classes.grep(SIZES), "#{path} does not set its title at text-3xl"
    assert_includes classes, 'font-semibold', "#{path} does not set its title semibold"
    assert_includes classes, 'text-gray-900', "#{path} does not set its title in the title colour"
  end
end

describe 'the title on a page you are signed in for' do
  include Rack::Test::Methods
  include PageTitle

  before do
    @account_id = sign_in
    @exercise = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id: @account_id)
    @workout = DB[:workouts].insert(account_id: @account_id, date: Date.today)
    @set = DB[:sets].insert(workout_id: @workout, exercise_id: @exercise, weight: 135, reps: 5,
                            is_warmup: false, is_completed: false)
    @program = Tectonic::Program.create(account_id: @account_id, name: 'Block 1', start_date: Date.today)
  end

  # The whole of what #115 measured, bar /authorize, which is behind a registered client
  # and a PKCE walk that oauth_spec owns. Three pages are absent because they have no
  # title at all and #129 did not ask for one: /workouts/:id/sets/new,
  # /workouts/:id/sets/:id/edit and /about.
  it 'is an h1 at one size, on every page' do
    ['/', '/start', '/workouts', '/workouts/new', "/workouts/#{@workout}",
     "/workouts/#{@workout}/edit", "/workouts/#{@workout}/session", "/workouts/#{@workout}/sets",
     "/workouts/#{@workout}/sets/#{@set}", '/exercises', '/exercises/new', "/exercises/#{@exercise}",
     "/exercises/#{@exercise}/edit", '/programs', "/programs/#{@program.id}", '/equipment',
     '/connections', '/volume'].each { |path| assert_page_title(path) }
  end

  # The same field is called four things in four templates, and this was the fifth: the
  # column name, rendered to whoever is logging a set.
  it 'asks for a warmup in words rather than in column names on a new set' do
    get "/workouts/#{@workout}/sets/new"
    labels = last_response.body.scan(%r{<label[^>]*>([^<]*)</label>}).flatten.map(&:strip)

    assert_includes labels, 'Warmup set'
    assert_includes labels, 'Completed'
    assert_empty labels.grep(/\Ais_/)
  end
end

describe 'the title on a page you reach signed out' do
  include Rack::Test::Methods
  include PageTitle

  it 'is an h1 at one size there too' do
    ['/login', '/create-account'].each { |path| assert_page_title(path) }
  end
end

