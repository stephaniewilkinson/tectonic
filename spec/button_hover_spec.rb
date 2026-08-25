# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What the primary button does under a pointer, asserted against the markup of every page
# that carries one.
#
# The button is written out by hand at two dozen sites and it had five hover behaviours.
# Eight of them hovered to gray-500, which on a control is what disabled looks like -- and
# that survived review for a while because white on gray-500 is 4.83:1 against lime-500's
# 1.98:1, so the broken state was the more legible one. Nine more named their own resting
# colour as the hover, so nothing moved at all. One went lighter rather than darker, and
# the sky buttons all turned lime, which says the two brand colours are interchangeable.
#
# None of that fails a spec on its own: the page renders, the button works, and the only
# symptom is the wrong colour under somebody's pointer. So the rule is pinned here --
# lime-500 to lime-600, lime-600 to lime-700, sky-800 to sky-900, one step down its own
# scale -- rather than left to be noticed.
module ButtonHover
  # Any step on the scale, not only the ones buttons rest at: the calendar's day tints are
  # bg-lime-100 and bg-sky-100 and they already hover a step down, so they are held to the
  # rule here too rather than excluded by a pattern that only knows about buttons. A
  # calendar change that fails this file is failing for that reason.
  RESTING = /\Abg-(lime|sky)-(\d00)\z/
  # Deliberately any hue: a grey or a lime hover on a sky button has to reach the
  # assertion to be caught, rather than being filtered out before it gets there.
  HOVERED = /\Ahover:bg-[a-z]+-\d00\z/

  def class_lists(body) = body.scan(/class="([^"]*)"/m).flatten.map(&:split)

  # Every element carrying both a brand background and a hover background, as the pair.
  def hover_pairs(body)
    class_lists(body).filter_map do |classes|
      resting = classes.grep(RESTING).first
      hovered = classes.grep(HOVERED).first
      [resting, hovered] if resting && hovered
    end
  end

  def assert_hover_steps_down_its_own_scale(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    pairs = hover_pairs(last_response.body)

    refute_empty pairs, "#{path} has no brand button left on it to check"
    pairs.each do |resting, hovered|
      hue, step = RESTING.match(resting).captures

      assert_equal "hover:bg-#{hue}-#{step.to_i + 100}", hovered,
                   "#{resting} on #{path} hovers to #{hovered}"
    end
  end
end

describe 'the buttons on the pages a visitor sees' do
  include Rack::Test::Methods
  include RouteOwnership
  include ButtonHover

  # welcome.erb's Log in rests at lime-600 rather than lime-500, so it is the one button
  # in the app whose hover is lime-700. It used to hover to lime-500 and got lighter.
  it 'steps every one of them down its own scale' do
    ['/welcome', '/login', '/create-account'].each { |path| assert_hover_steps_down_its_own_scale(path) }
  end

  # The two links between the account pages named text-lime-500 as both states, so
  # pointing at them did nothing whatsoever. Which lime a link should be is #127's
  # question and it will move these again; that they move at all is this one.
  it 'moves the link to the other account page as well' do
    ['/login', '/create-account'].each do |path|
      get path
      pairs = class_lists(last_response.body).filter_map do |classes|
        resting = classes.grep(/\Atext-lime-\d00\z/).first
        hovered = classes.grep(/\Ahover:text-lime-\d00\z/).first
        [resting, hovered] if resting && hovered
      end

      refute_empty pairs, "#{path} has no lime link left on it to check"
      pairs.each { |resting, hovered| refute_equal "hover:#{resting}", hovered, "#{resting} on #{path} does not move" }
    end
  end
end

describe 'the buttons on the pages an account sees' do
  include Rack::Test::Methods
  include RouteOwnership
  include ButtonHover

  before do
    @account_id = login
    @workout = own_workout(@account_id)
    @exercise = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id: @account_id)
    @set = DB[:sets].insert(workout_id: @workout, exercise_id: @exercise, weight: 225, reps: 5,
                            is_warmup: false, is_completed: false)
  end

  # The workout record is the page the complaint was written about: its two buttons are
  # the only two things to do there, they are the brand pair side by side, and both of
  # them turned grey.
  it 'steps every one of them down its own scale' do
    ['/', '/start', '/logout', '/equipment', '/programs',
     '/workouts', '/workouts/new', "/workouts/#{@workout}",
     "/workouts/#{@workout}/sets", "/workouts/#{@workout}/sets/new",
     "/workouts/#{@workout}/sets/#{@set}/edit",
     '/exercises', '/exercises/new', "/exercises/#{@exercise}"].each do |path|
      assert_hover_steps_down_its_own_scale(path)
    end
  end
end

