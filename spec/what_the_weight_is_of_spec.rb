# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# A set row saying which of its two numbers is per side. #502.
#
# The row read "39 lb × 8 per side", and "per side" at the end of that postmodifies the whole
# phrase rather than the count -- so the weight looks per side too. On a Single-Leg DB RDL the
# misreading is *nearly* right, which is what makes it hard to catch: a stored dumbbell weight
# is one dumbbell (`dumbbell_totals` stands the handle where a bar stands and loads both its
# ends), so 39 lb really is what one hand holds and the pair is 78. Three readings of one
# phrase, two of them wrong by exactly 2x, and nothing on the screen to settle it.
#
# Two halves, and the second is not optional. Binding the qualifier to the count fixes the
# grammar and leaves a reader newly confident that the 39 is the whole load -- which on a pair
# is the 2x error, now held with conviction. So the row also says what the weight is of.
module WhatTheWeightIsOf
  # One working set, with the movement's shape as the argument under test. Not on a bar by
  # default, since every question here is about the rack the plate math cannot speak for.
  def a_row(is_barbell: false, dumbbell_count: nil, weight: 39, reps: 8, is_per_side: true)
    account_id = login
    workout_id = own_workout(account_id)
    exercise_id = DB[:exercises].insert(name: "Single-Leg DB RDL #{SecureRandom.hex(4)}",
                                        account_id:, is_barbell:, dumbbell_count:,
                                        default_is_per_side: is_per_side)
    DB[:sets].insert(workout_id:, exercise_id:, weight:, reps:, is_barbell:, is_per_side:,
                     is_warmup: false, is_completed: false)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end
end

describe 'the count naming its unit' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatTheWeightIsOf

  it 'binds per side to the reps rather than to the phrase' do
    assert_includes a_row, '39 lb × 8 reps per side'
  end

  # The ordinary set is almost every set, and "5 reps" on every bench press would be a worse
  # row than the one this replaces -- the load in front of the count already says what it is.
  it 'leaves a bilateral count bare' do
    body = a_row(is_barbell: true, weight: 155, reps: 5, is_per_side: false)

    assert_includes body, '155 lb × 5'
    refute_includes body, '155 lb × 5 reps'
  end

  # Unweighted work said "8 reps" before this and still does: with no load in front of it the
  # count has nothing to be confused with, which is the same reason the unit is added above.
  it 'still spells out a count with no load in front of it' do
    assert_includes a_row(weight: nil, is_per_side: false), '8 reps'
  end
end

describe 'the row saying what the weight is of' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatTheWeightIsOf

  it 'names the pair where the movement is done with two' do
    body = a_row(dumbbell_count: 2)

    assert_includes body, 'Dumbbells'
    assert_includes body, 'two at 39 lb'
  end

  # Said on a single too. "one at 39 lb" looks like it adds nothing, but it is the answer to
  # the same question, and a line appearing only on pairs would leave every single-arm row
  # ambiguous in exactly the way this exists to fix.
  it 'names the single where the movement is done with one' do
    assert_includes a_row(dumbbell_count: 1), 'one at 39 lb'
  end
end

# The silence is the load-bearing half. `is_barbell` being false is not the same claim as
# "this is a dumbbell": a cable stack, a machine and a weighted pull-up are all on that side
# of the line, and "two dumbbells" on a lat pulldown would be a new wrong answer in place of
# a silence.
describe 'a weight the app has not been told the shape of' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatTheWeightIsOf

  # The case on the screenshot in #502: the movement has never said how many, so the plate
  # math assumes a pair to keep the prescription loadable (Equipment::DEFAULT_DUMBBELLS) --
  # and an assumption made for that reason is not a fact to read back to somebody at the rack.
  it 'says nothing where the movement has not said how many' do
    refute_includes a_row(dumbbell_count: nil), 'Dumbbells'
  end

  it 'says nothing about a barbell, which has plate math instead' do
    body = a_row(is_barbell: true, dumbbell_count: 2, weight: 155)

    refute_includes body, 'Dumbbells'
    assert_includes body, 'Plate math'
  end

  # Nothing weighs the bodyweight row, so there is no number for the line to be about.
  it 'says nothing where there is no load' do
    refute_includes a_row(dumbbell_count: 2, weight: nil), 'Dumbbells'
  end
end

