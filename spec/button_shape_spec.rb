# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What shape the primary button is, asserted against the markup of every page that draws
# one.
#
# Written out by hand at two dozen sites it came to three corner radii, two shadow states
# and two focus rings. Only one of those is visible in a screenshot of a page at rest, so
# the ones that mattered most went unnoticed longest: thirteen of the buttons named no
# focus style at all and fell through to whatever the browser draws, which in Firefox is a
# blue ring on a lime button. And `shadow-ss` -- not a Tailwind class, silently ignored --
# left the Save on the exercise form flat while the identical Save on the workout form was
# raised.
#
# None of that fails a spec on its own: every one of those pages renders and every one of
# those buttons submits. So the rule is pinned here instead. `button_style` is the one
# place the shape is written now, but a call site can still leave a rounded-lg of its own
# behind next to it, which is why this checks the rendered class list rather than the
# helper.
module ButtonShape
  # The three fills a primary button rests at: lime-500 everywhere, lime-600 on the
  # marketing page's Log in, sky-800 on the ones that go to a thing that already exists.
  # Deliberately not every lime in the markup -- the calendar tints, the progress bar and
  # the nav are lime too and none of them is a button.
  FILL = /\Abg-(?:lime-500|lime-600|sky-800)\z/
  # Only the elements that can actually take focus. A tint on a div cannot draw a focus
  # ring and has no business carrying one.
  CONTROL = /<(?:a|button|input)\b[^>]*class="([^"]*)"/
  SHAPE = %w[rounded-md shadow-sm focus-visible:outline focus-visible:outline-2
             focus-visible:outline-offset-2 focus-visible:outline-lime-500].freeze

  def filled_controls(body)
    body.scan(CONTROL).flatten.map(&:split).select { |classes| classes.grep(FILL).any? }
  end

  def assert_one_shape(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    controls = filled_controls(last_response.body)

    refute_empty controls, "#{path} has no primary button left on it to check"
    controls.each { |classes| assert_shape(classes, path) }
  end

  def assert_shape(classes, path)
    missing = SHAPE - classes

    assert_empty missing, "a button on #{path} is missing #{missing.join(' ')}"
    # Present is not enough: a call site that keeps its old radius alongside the shared one
    # leaves which of the two wins to the order Tailwind happens to emit them in.
    assert_equal ['rounded-md'], classes.grep(/\Arounded/), "a button on #{path} has a radius of its own"
    assert_equal ['shadow-sm'], classes.grep(/\Ashadow/), "a button on #{path} has a shadow of its own"
  end
end

describe 'the primary button on the pages a visitor sees' do
  include Rack::Test::Methods
  include RouteOwnership
  include ButtonShape

  it 'is one shape on all of them' do
    ['/welcome', '/login', '/create-account'].each { |path| assert_one_shape(path) }
  end
end

describe 'the primary button on the pages an account sees' do
  include Rack::Test::Methods
  include RouteOwnership
  include ButtonShape

  before do
    @account_id = login
    @workout = own_workout(@account_id)
    @exercise = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id: @account_id)
    @set = DB[:sets].insert(workout_id: @workout, exercise_id: @exercise, weight: 225, reps: 5,
                            is_warmup: false, is_completed: false)
    # A warmup as well as a working set, because the session screen draws its Done button
    # at two sizes and the smaller one is the first thing anybody taps in a session.
    DB[:sets].insert(workout_id: @workout, exercise_id: @exercise, weight: 45, reps: 5,
                     is_warmup: true, is_completed: false)
    @program = Tectonic::Program.create(account_id: @account_id, name: 'Block 0', start_date: Date.today)
  end

  it 'is one shape on all of them' do
    ['/', '/start', '/logout', '/settings', '/volume', '/programs', "/programs/#{@program.id}",
     '/workouts', '/workouts/new', "/workouts/#{@workout}",
     "/workouts/#{@workout}/sets", "/workouts/#{@workout}/sets/new",
     "/workouts/#{@workout}/sets/#{@set}/edit", "/workouts/#{@workout}/session",
     '/exercises', '/exercises/new', "/exercises/#{@exercise}"].each do |path|
      assert_one_shape(path)
    end
  end
end

