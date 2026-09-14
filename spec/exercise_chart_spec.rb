# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The exercise page hands its chart to Chartkick in an inline script, so Rack::Test can
# read the plotted points straight out of the rendered body and no browser is needed.
# What is worth asserting is that the page renders with a line on it and that the points
# are one per recorded day at that day's heaviest weight; what Chart.js paints from them
# is the library's business.
#
# The chart itself changed in #434 -- it is now one of five series rather than the whole of
# the picture -- and what this file asserts about it did not: one point per session, at the
# heaviest *working* set, and no chart at all where there is nothing to draw. The series it
# grew are specced in progress_chart_spec.rb.
module ExerciseChart
  def app
    Tectonic.app
  end

  def make_account
    email = "#{SecureRandom.hex}@example.com"
    password = 'pw12345678'
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create(password), created_on: Time.now)
    [email, password]
  end

  # A signed-in account with a lift of its own to log sets against.
  def sign_in_with_a_lift
    email, password = make_account
    get '/login'
    post '/login', { login: email, password:, '_csrf' => last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1] }
    @account_id = DB[:accounts].where(email:).get(:id)
    @exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id: @account_id)
  end

  # One set on a given day, in that day's workout, which is created on first use. The
  # date carries a time of day, as a workout logged through the app does, so the
  # grouping is exercised against the timestamps it will really meet.
  def log_set(weight, on:, is_warmup: false)
    workout_id = DB[:workouts].where(account_id: @account_id, date: on).get(:id) ||
                 DB[:workouts].insert(account_id: @account_id, date: on)
    DB[:sets].insert(workout_id:, exercise_id: @exercise_id, weight:, reps: 5,
                     is_warmup:, is_completed: true)
  end
end

describe 'the exercise page' do
  include Rack::Test::Methods
  include ExerciseChart

  # Two days, each with more than one set, and on the second a warmup heavier than the
  # work: one point per day, at the heaviest weight worked, warmups left out.
  it 'plots the heaviest weight recorded on each day' do
    sign_in_with_a_lift
    log_set 135, on: Time.new(2026, 3, 2, 7, 30)
    log_set 185, on: Time.new(2026, 3, 2, 7, 45)
    log_set 155, on: Time.new(2026, 3, 9, 18, 15)
    log_set 225, on: Time.new(2026, 3, 9, 18, 20), is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'new Chartkick["LineChart"]'
    assert_includes last_response.body, '"name":"Heaviest set","data":[["2026-03-02",185],["2026-03-09",155]]'
  end

  # **This reverses what this spec used to assert, and the reversal is the point of #434.**
  #
  # The old chart asked Chartkick for `discrete: true`, which spaces the recorded days evenly
  # and makes a five-month layoff look exactly like a week off. That was the right trade for
  # the question that chart answered -- is the weight going up -- and it is the wrong one for
  # the question this chart answers, which is whether it is going up *fast enough*. Pace is
  # about elapsed time, so the layoff has to look like a layoff, and the goal has to sit at
  # its own date rather than one column to the right of the last session.
  #
  # Asserted as the absence of the flag plus real dates in the data, because that pair is what
  # makes Chart.js read the keys as a timeline.
  it 'puts a lift picked up months later where the calendar puts it' do
    sign_in_with_a_lift
    log_set 185, on: Time.new(2026, 1, 5, 7, 30)
    log_set 190, on: Time.new(2026, 6, 15, 7, 30)

    get "/exercises/#{@exercise_id}"

    assert_includes last_response.body, '[["2026-01-05",185],["2026-06-15",190]]'
    refute_includes last_response.body, '"discrete":true'
  end
end

# **The bug no assertion caught, now one does.**
#
# Chartkick merges every series onto one shared axis -- the union of all their dates -- and pads
# each with nulls where it has no value there. The training max has a point at each block
# opening and one for today, so on the session dates in between it is null. Chart.js does not
# join a line across a null, and with `pointRadius: 0` the surviving points draw nothing at all.
#
# The result was a legend entry reading "Training max" above a canvas with no such line on it.
# The series had the right points, the dataset was in the payload, and Chart.js reported it
# visible. A screenshot found it; nothing else would have.
describe 'a line whose points are not on every date the axis has' do
  include Rack::Test::Methods
  include ExerciseChart

  it 'is told to span the gaps, or it draws nothing at all' do
    sign_in_with_a_lift
    log_set 185, on: Time.new(2026, 3, 2, 7, 30)

    get "/exercises/#{@exercise_id}"

    assert_includes last_response.body, '"name":"Training max"'
    assert_includes last_response.body, '"spanGaps":true'
  end
end

# The 215KB date adapter, which the layout deliberately stopped loading and left a note saying
# would be needed again by "a chart that wants a real calendar". This is that chart.
describe 'what a real calendar costs the page' do
  include Rack::Test::Methods
  include ExerciseChart

  it 'loads the date adapter that a real calendar needs' do
    sign_in_with_a_lift
    log_set 185, on: Time.new(2026, 1, 5, 7, 30)

    get "/exercises/#{@exercise_id}"

    assert_includes last_response.body, 'chartjs-adapter-date-fns'
  end
end

describe 'an exercise with nothing but warmups logged' do
  include Rack::Test::Methods
  include ExerciseChart

  # The page still lists the sets; it is the chart that has nothing to draw, and a lone
  # axis reads worse than no chart at all.
  #
  # This nearly stopped being true in #434. The estimated-1RM series first included warmups,
  # on the reasoning that a submaximal rung cannot win the estimate -- which holds whenever
  # there are working sets and fails in exactly this case, where it would have drawn a chart
  # whose only content was a max estimated from a warmup. #211 settled what that number is
  # worth. This spec is what caught it.
  it 'draws no chart' do
    sign_in_with_a_lift
    log_set 45, on: Time.new(2026, 3, 2, 7, 30), is_warmup: true

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, '45'
    refute_includes last_response.body, 'new Chartkick'
  end
end

describe 'an exercise with nothing logged at all' do
  include Rack::Test::Methods
  include ExerciseChart

  it 'says so and draws no chart' do
    sign_in_with_a_lift

    get "/exercises/#{@exercise_id}"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'No sets logged yet.'
    refute_includes last_response.body, 'new Chartkick'
  end
end

