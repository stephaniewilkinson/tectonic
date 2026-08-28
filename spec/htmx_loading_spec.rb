# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require

# Which pages load htmx. #237.
#
# It is 50KB and it was on every page in the app, while being used on three. /exercises,
# /volume, /programs and /about each parsed and ran it to do nothing whatsoever -- and the
# front page and /about are the two likeliest first visits, neither of which uses it.
#
# Making it conditional introduces a failure that says nothing. A page that carries hx-
# attributes and does not load htmx still works: the forms post normally and the routes
# redirect, because every one of them was written to degrade that way. It is simply slower
# and loses the swap, and nothing on screen announces it. So the two are held together here
# rather than left to be spotted.
#
# Walked as a list of paths rather than as a list of templates, because what matters is what
# a browser is served. A partial that sets the flag but is never rendered, or one that is
# rendered through a route nobody thought about, are both cases a template-reading test
# would get wrong.
module HtmxLoading
  def app = Tectonic.app

  SCRIPT = '/js/htmx.min.js'

  # Enough of the app to cover both answers: the two screens that drive htmx and six that do
  # not. The signed-out pair are here because they are the likeliest first visit, which is
  # the visit the 50KB cost most.
  #
  # /programs/:id is in the list for a reason. Grepping views/ for "hx-" says it uses htmx,
  # and it does not: both matches are prose, one of them a note that it carried an
  # hx-confirm once and no longer does. It is here so that the difference between an
  # attribute and a sentence about an attribute is checked rather than eyeballed.
  def pages(workout_id, program_id)
    ["/workouts/#{workout_id}/session", '/workouts', "/programs/#{program_id}",
     '/exercises', '/volume', '/about', '/welcome', "/workouts/#{workout_id}", '/programs']
  end

  # A program with one lift on it, because programs/_lift.erb is what carries the hx-
  # attributes there and /programs, the index, renders none of them.
  def a_program(account_id)
    program_id = DB[:programs].insert(account_id:, name: "Block #{SecureRandom.hex(4)}", start_date: Date.today)
    week_id = DB[:program_weeks].insert(program_id:, number: 1)
    day_id = DB[:program_days].insert(program_week_id: week_id, weekday: 1, focus: 'Squat')
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    DB[:program_lifts].insert(program_day_id: day_id, exercise_id:, sets: 3, reps: 5)
    program_id
  end

  def a_session(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 135, reps: 5,
                     is_warmup: false, is_completed: false, is_barbell: true)
    workout_id
  end

  # What the page actually is: whether it drives htmx, and whether it loaded it.
  def audit(path)
    get path
    body = last_response.body

    { path:, uses: body.match?(/\shx-[a-z]+=/), loads: body.include?(SCRIPT) }
  end
end

describe 'the pages that load htmx' do
  include Rack::Test::Methods
  include RouteOwnership
  include HtmxLoading

  before do
    @account_id = login
    @workout_id = a_session(@account_id)
    @program_id = a_program(@account_id)
    @audits = pages(@workout_id, @program_id).map { |path| audit(path) }
  end

  # The bug this closes. Four of these pages carried 50KB of JavaScript for nothing.
  it 'does not load it on a page with no hx- attribute on it' do
    idle = @audits.reject { |page| page[:uses] }

    refute_empty idle, 'this spec is checking nothing if every page drives htmx'
    idle.each { |page| refute page[:loads], "#{page[:path]} loads htmx and has no use for it" }
  end

  # The failure the conditional introduces, which is the quiet one: the forms still post and
  # the routes still redirect, so a page missing its script looks like it works.
  it 'loads it on every page that has one' do
    driving = @audits.select { |page| page[:uses] }

    refute_empty driving, 'this spec is checking nothing if no page drives htmx'
    driving.each { |page| assert page[:loads], "#{page[:path]} uses hx- attributes without loading htmx" }
  end

  # Named so a failure above reads as a change of intent rather than as a mystery.
  it 'is the session screen and the workouts list, and nothing else' do
    assert_equal(["/workouts/#{@workout_id}/session", '/workouts'],
                 @audits.select { |page| page[:uses] }.map { |page| page[:path] })
  end
end

