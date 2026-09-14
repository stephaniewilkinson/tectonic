# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# The movement page tells "nothing logged" apart from "logged, and the estimate cannot read it".
#
# Reported against a Bulgarian Split Squat carrying two completed working sets of 44x8 at RPE 7.
# The page said **"Nothing has been lifted here that the chart can read"** and then told the
# lifter to log a completed set -- which they had done twice.
#
# The app was right that it had no number and wrong about why. `OneRepMax` restates a rated set
# as the RPE-8 set of equal difficulty -- eight reps at 7 is nine at 8 -- and
# `SetScheme::RPE8_PERCENTS` stops at five, so neither set could be read. That is a real limit
# and this does not change it; what it changes is an app claiming nothing was logged while the
# set list sits further down the same page.
module UnreadableSets
  # The reported set, exactly: eight reps at RPE 7 restates to nine at RPE 8, which is off the
  # end of the table.
  def a_movement_trained_in_eights(account_id)
    exercise = Tectonic::Exercise.create(account_id:, name: "Split Squat #{SecureRandom.hex(4)}")
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    2.times do
      DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 44, reps: 8, rpe: 7,
                       is_warmup: false, is_completed: true)
    end
    exercise
  end

  # The body with its HTML whitespace collapsed, because a sentence wrapped across ERB lines
  # arrives with newlines and indentation inside it. A browser collapses those and a reader
  # never sees them, so an assertion that does not would be testing the shape of the template
  # rather than what the page says.
  def said
    last_response.body.gsub(/\s+/, ' ')
  end

  def a_movement_with_nothing_logged(account_id)
    Tectonic::Exercise.create(account_id:, name: "Curl #{SecureRandom.hex(4)}")
  end

  # Five reps at RPE 8 sits exactly on the end of the table, so this one reads.
  def a_movement_the_estimate_reads(account_id)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5, rpe: 8,
                     is_warmup: false, is_completed: true)
    exercise
  end
end

describe 'a movement whose sets the estimate cannot read' do
  include Rack::Test::Methods
  include RouteOwnership
  include UnreadableSets

  before do
    @account_id = login
    @exercise = a_movement_trained_in_eights(@account_id)
    get "/exercises/#{@exercise.id}"
  end

  # The whole of the bug. A lifter reads "nothing has been lifted here" as a claim about their
  # training, and it was false.
  it 'does not claim nothing has been lifted' do
    refute_match(/Nothing has been (lifted|logged)/i, said)
  end

  # An app claiming nothing was logged while the set list sits further down the same page is an
  # app the lifter stops believing, so the count is said out loud.
  it 'says how many sets are there' do
    assert_match(/2 completed working sets are logged here/, said)
  end

  it 'says why they cannot be read rather than only that they cannot' do
    assert_includes said, 'five reps or fewer'
  end

  # The advice was the other half of the bug: "log a completed set", to somebody who had logged
  # two, and logging a third of the same would not have helped.
  it 'points at the box on this page rather than at logging more of the same' do
    assert_includes said, 'Set a max below'
  end
end

describe 'a movement with nothing logged at all' do
  include Rack::Test::Methods
  include RouteOwnership
  include UnreadableSets

  before do
    @account_id = login
    @exercise = a_movement_with_nothing_logged(@account_id)
    get "/exercises/#{@exercise.id}"
  end

  # The state the old message was written for, which is still a state and still says so.
  it 'says so plainly' do
    assert_includes said, 'Nothing has been logged here yet'
  end

  # And here the advice is right, because there genuinely is nothing.
  it 'suggests logging a set, which is the thing that would help' do
    assert_includes said, 'log a completed set'
  end
end

describe 'a movement the estimate can read' do
  include Rack::Test::Methods
  include RouteOwnership
  include UnreadableSets

  it 'reports the number instead of any of that' do
    account_id = login
    exercise = a_movement_the_estimate_reads(account_id)

    get "/exercises/#{exercise.id}"

    assert_includes said, 'an estimated one-rep max'
    refute_match(/cannot read/, said)
  end
end

# The count is of completed *working* sets, because those are the ones the estimate would have
# read. A page that counted warmups would announce "5 sets are logged" about a ramp and send
# somebody looking for training that is not there.
describe 'what the count counts' do
  include Rack::Test::Methods
  include RouteOwnership
  include UnreadableSets

  it 'ignores warmups and sets that were never completed' do
    account_id = login
    exercise = a_movement_trained_in_eights(account_id)
    workout_id = DB[:workouts].where(account_id:).get(:id)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 20, reps: 8,
                     is_warmup: true, is_completed: true)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 44, reps: 8, rpe: 7,
                     is_warmup: false, is_completed: false)

    get "/exercises/#{exercise.id}"

    assert_match(/2 completed working sets are logged here/, said)
  end
end

