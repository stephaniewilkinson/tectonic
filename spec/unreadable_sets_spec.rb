# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What the movement page says when it has no training max, which has now been wrong twice and
# is worth pinning properly.
#
# Reported against a Bulgarian Split Squat carrying two completed working sets of 44x8 at RPE 7.
# The page said **"Nothing has been lifted here that the chart can read"** and then told the
# lifter to log a completed set -- which they had done twice.
#
# The first fix said the sets were there and the estimate could not read them. True then: the
# chart stopped at five reps and eight at RPE 7 restates to nine.
#
# The chart reads to ten now, so it is not true any more. Those sets *do* estimate a max -- 44
# at 70.7% is about 62 lb -- and what they do not do is produce a number the app will let set
# the denominator by itself. So the page shows the number and says why it is not being used,
# which is the third and hopefully last shape of this sentence.
module UnreadableSets
  # The reported set, exactly: eight reps at RPE 7 restates to nine at RPE 8 -- readable since
  # the row was extended, and further from a single than CONFIDENT_REPS allows to set a max.
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

describe 'a movement whose estimate is too far from a single to trust with a max' do
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

  # The number exists and is shown. Withholding it was the dead end; the honesty moved onto
  # saying what it is rather than onto pretending there is nothing.
  it 'reports the estimate rather than withholding it' do
    assert_match(%r{estimate a one-rep max of about <strong>62 lb</strong>}, said)
  end

  it 'says how far from a single the set it read was' do
    assert_includes said, 'as hard as 9 reps'
  end

  # And the rule that makes showing it safe.
  it 'says why it is not the number percentages come off' do
    assert_includes said, 'will not make it the number your percentages come off'
  end
end

describe 'what that page tells a lifter to do about it' do
  include Rack::Test::Methods
  include RouteOwnership
  include UnreadableSets

  before do
    @account_id = login
    @exercise = a_movement_trained_in_eights(@account_id)
    get "/exercises/#{@exercise.id}"
  end

  # The advice was the other half of the original bug: "log a completed set", to somebody who
  # had logged two, and a third of the same would not have helped.
  it 'points at the box on this page rather than at logging more of the same' do
    assert_includes said, 'Set a max below'
  end

  # The whole reason this state exists rather than resolving to a derived max.
  it 'still refuses to generate a percentage lift against it' do
    assert_nil Tectonic::TrainingMax.for(account_id: @account_id, exercise: @exercise)
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

