# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'
require 'date'

# A session keeps the date it was trained on. #440.
#
# `views/workouts/_form.erb` is shared by the new page and the edit page, and its date input
# carried `value="<%= Date.today %>"` unconditionally. So the edit page opened with the wrong
# date in the box every time -- and because the field is `required` and posted with everything
# else, saving *any* edit moved the session to today.
#
# Two consequences, and the issue title names both. A session could not be corrected onto a
# past date, because the box would not hold one long enough to submit it. And renaming a
# session from three weeks ago dragged it, and its twelve completed sets with their ratings,
# onto the current day without saying anything.
#
# Reported as workout 28: created 2026-08-30, trained 2026-08-31, twelve completed sets filed a
# day early with no way to move them.
module KeepingTheDate
  def a_session_on(account_id, date, name: 'Squat day')
    Tectonic::Workout.insert(account_id:, date:, name:)
  end

  def edit_page(workout_id)
    get "/workouts/#{workout_id}/edit"
    last_response.body
  end

  # Posts the edit form the way the browser does: every field it carries, together.
  def save(workout_id, date:, name: 'Renamed', note: '')
    post '/workouts', { 'id' => workout_id.to_s, 'date' => date, 'name' => name, 'note' => note,
                        '_csrf' => token_for("/workouts/#{workout_id}/edit") }
  end

  def date_of(workout_id) = Tectonic::Workout[workout_id].date.to_date

  # The date the rendered form is actually carrying, which is what a browser posts back when
  # somebody edits the name and nothing else. Taken off the page rather than passed in,
  # because a spec that supplies the right date itself cannot fail on the bug -- the whole
  # fault was the value the page put in the box.
  def date_in_form(workout_id)
    edit_page(workout_id)[/<input[^>]*id="date"[^>]*>/][/value="([^"]*)"/, 1]
  end
end

describe 'the date the edit page opens with' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before do
    @account_id = login
    @trained_on = Date.today - 21
    @workout = a_session_on(@account_id, @trained_on)
  end

  # The bug, at its source. Everything below follows from this one value being wrong.
  it 'is the day it was trained, not today' do
    assert_includes edit_page(@workout), "value=\"#{@trained_on.strftime('%m/%d/%Y')}\""
  end

  it 'is not today' do
    refute_includes edit_page(@workout), "value=\"#{Date.today.strftime('%m/%d/%Y')}\""
  end
end

# What the wrong value cost, which is the part a lifter would actually notice.
describe 'renaming a session from three weeks ago' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  before do
    @account_id = login
    @trained_on = Date.today - 21
    @workout = a_session_on(@account_id, @trained_on)
  end

  # Posting the form back unchanged is what a browser does when somebody edits the name. It
  # used to carry today's date along with it and move the session.
  it 'leaves it where it was' do
    save(@workout, date: date_in_form(@workout))

    assert_equal @trained_on, date_of(@workout)
  end

  it 'still renames it' do
    save(@workout, date: @trained_on.strftime('%m/%d/%Y'), name: 'Heavy squats')

    assert_equal 'Heavy squats', Tectonic::Workout[@workout].name
  end
end

# And the correction the issue asked for: a session trained a day after it was written, moved
# onto the day it happened. This always worked at the route -- #319 made POST /workouts with an
# id update the date -- and could not be reached through the page.
describe 'correcting a session onto the day it actually happened' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  it 'moves it, and the sets go with it' do
    account_id = login
    written_for = Date.new(2026, 8, 30)
    workout = a_session_on(account_id, written_for)
    exercise_id = DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout, exercise_id:, weight: 155, reps: 5, rpe: 8,
                     is_warmup: false, is_completed: true, completed_at: Time.now)

    save(workout, date: '08/31/2026')

    assert_equal Date.new(2026, 8, 31), date_of(workout)
    # The sets are reached through the workout rather than dated themselves, so they follow it
    # without anything having to move them. That is why a date editor is the whole fix here.
    assert_equal 1, Tectonic::WorkoutSet.where(workout_id: workout).count
  end
end

# The new page has no session to read a date off, and must go on opening at today.
describe 'writing a new session' do
  include Rack::Test::Methods
  include RouteOwnership
  include KeepingTheDate

  it 'still opens at today' do
    login

    get '/workouts/new'

    assert_includes last_response.body, "value=\"#{Date.today.strftime('%m/%d/%Y')}\""
  end
end

