# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# Half a pound, which the app could not hold. `weight` was an integer on both the set and
# the prescription, so 1.25 lb pairs -- ordinary equipment, and the smallest useful jump
# for an upper-body lift that has stalled -- could not be logged, and neither could most
# machine stacks. #132 chose step="1" over step="any" on every weight input for exactly
# that reason: the browser would have accepted 137.5, the column would have refused it,
# and the lifter would have been told nothing.
module DecimalWeight
  def a_set(account_id, weight:)
    workout = DB[:workouts].insert(account_id:, date: Time.now)
    exercise = DB[:exercises].insert(name: "Bench #{SecureRandom.hex(4)}", account_id:, is_barbell: true)
    id = DB[:sets].insert(workout_id: workout, exercise_id: exercise, weight:, reps: 5,
                          is_warmup: false, is_completed: true, is_barbell: true)
    [workout, exercise, id]
  end
end

describe 'a weight with a half pound in it' do
  include Rack::Test::Methods
  include RouteOwnership
  include DecimalWeight

  before { @account_id = login }

  it 'survives the round trip to the column and back' do
    _, _, set_id = a_set(@account_id, weight: 137.5)

    assert_in_delta 137.5, Tectonic::Set[set_id].weight.to_f
  end

  # The point of numeric over float: these are compared against a prescription and summed
  # into tonnage, and binary floating point cannot be relied on to make 135 + 2.5 equal to
  # anything in particular.
  it 'is exact rather than approximately itself' do
    _, _, set_id = a_set(@account_id, weight: 137.5)

    assert_equal BigDecimal('137.5'), Tectonic::Set[set_id].weight
    assert_equal BigDecimal('140'), Tectonic::Set[set_id].weight + BigDecimal('2.5')
  end
end

# Every site that prints a weight would otherwise start showing a BigDecimal, which
# renders as "0.1375e3" -- correct, and no use to anybody holding a bar.
describe 'how a decimal weight reads' do
  include Rack::Test::Methods
  include RouteOwnership
  include DecimalWeight

  before { @account_id = login }

  it 'prints a whole weight without a decimal point on it' do
    assert_equal 225, Tectonic.new({}).weight_label(BigDecimal('225'))
    assert_equal 137.5, Tectonic.new({}).weight_label(BigDecimal('137.5'))
    assert_nil Tectonic.new({}).weight_label(nil)
  end

  it 'reads as 137.5 on the pages that show a set' do
    workout, exercise, set_id = a_set(@account_id, weight: 137.5)

    ["/workouts/#{workout}", "/workouts/#{workout}/sets", "/workouts/#{workout}/sets/#{set_id}",
     "/exercises/#{exercise}", "/workouts/#{workout}/session"].each do |path|
      get path

      assert_equal 200, last_response.status, "#{path} did not render"
      assert_includes last_response.body, '137.5', "#{path} did not show the weight"
      refute_includes last_response.body, '0.1375e3', "#{path} printed a BigDecimal"
    end
  end

  # Chartkick serialises whatever it is handed, and a BigDecimal goes into the page as the
  # string "0.1375e3", which Chart.js plots as nothing at all.
  it 'plots as a number rather than as a BigDecimal string' do
    _, exercise, = a_set(@account_id, weight: 137.5)

    get "/exercises/#{exercise}"

    assert_includes last_response.body, '137.5'
    refute_match(/"0\.\d+e\d"/, last_response.body)
  end
end

# #132's refusal was the column's, not the browser's, so it goes with the column.
describe 'what the weight inputs will now accept' do
  include Rack::Test::Methods
  include RouteOwnership
  include DecimalWeight

  before { @account_id = login }

  it 'is any number, on the set form and on the session screen' do
    workout, = a_set(@account_id, weight: 135)

    ["/workouts/#{workout}/sets/new", "/workouts/#{workout}/session"].each do |path|
      get path

      refute_match(/name="weight"[^>]*step="1"/, last_response.body, "#{path} still refuses a decimal")
      assert_match(/name="weight"[^>]*step="any"/, last_response.body, "#{path} has no weight input")
    end
  end

  it 'takes a decimal through the form and stores it' do
    workout, exercise, = a_set(@account_id, weight: 135)
    get "/workouts/#{workout}/sets/new"
    token = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post "/workouts/#{workout}/sets/new",
         { weight: '137.5', reps: '5', exercise_id: exercise.to_s, '_csrf' => token }

    assert_equal BigDecimal('137.5'), DB[:sets].where(workout_id: workout).order(:id).last[:weight]
  end
end

