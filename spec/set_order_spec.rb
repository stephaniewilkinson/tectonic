# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require

# What order the sets of a workout come out in, on the two pages that list them and in the
# association underneath both.
#
# #217. The complaint was that sets do not stay in the right order, and the reason they did
# not is that nothing asked them to: Workout's one_to_many carried no :order, so the list
# page emitted a SELECT with no ORDER BY, and the workout record sorted by exercise_id,
# which is not unique and so leaves the rows inside a card unordered too. Postgres may
# return an unordered SELECT however it likes and may change its mind after an UPDATE --
# which on this table is every Done tap and every corrected weight -- so the order held
# until somebody trained, and then stopped holding. A test that only reads a freshly
# inserted workout would have passed throughout, which is why each of these trains first.
module SetOrder
  def app
    Tectonic.app
  end

  # Two movements, warmups before working sets within each, written the way the generator
  # writes a session: in the order it is meant to be trained.
  #
  # The squat row is created after the bench row on purpose. exercise_id order would put
  # bench first, and the session says otherwise -- which is the whole of what the old sort
  # got wrong, and it cannot be seen at all if the two orders happen to agree.
  def trained_session
    account_id = login
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    bench = movement(account_id, @bench_name = "Bench #{SecureRandom.hex(4)}")
    squat = movement(account_id, @squat_name = "Squat #{SecureRandom.hex(4)}")
    ramp = [[squat, 45, true], [squat, 95, true], [squat, 135, false],
            [bench, 45, true], [bench, 95, false]]
    [account_id, workout_id, ramp.map { |lift| log(workout_id, *lift) }]
  end

  def movement(account_id, name)
    DB[:exercises].insert(name:, account_id:)
  end

  def log(workout_id, exercise_id, weight, is_warmup)
    DB[:sets].insert(workout_id:, exercise_id:, weight:, reps: 5, is_warmup:,
                     is_barbell: true, is_completed: false)
  end

  # The bit that used to shake the order loose. Completing a set rewrites the row, and an
  # unordered SELECT is free to hand back a rewritten row somewhere else entirely.
  def train(workout_id, set_id)
    post "/workouts/#{workout_id}/sets/#{set_id}/complete",
         { '_csrf' => token_for("/workouts/#{workout_id}/sets/#{set_id}/complete") }
  end

  # The sets down the page, in document order. Read off the links rather than off the
  # weights: both pages link every row to /workouts/:id/sets/:set_id, where only one of
  # them makes the weight itself the anchor, and an id says which set without depending on
  # two rows having different loads.
  def sets_listed_on(path)
    get path
    last_response.body.scan(%r{/sets/(\d+)}).flatten.map(&:to_i).uniq
  end
end

describe 'the order the sets of a workout are listed in' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetOrder

  before do
    @account_id, @workout_id, @set_ids = trained_session
    # Two of them, out of order, so no single row's rewrite could be mistaken for the fix.
    train(@workout_id, @set_ids[3])
    train(@workout_id, @set_ids[0])
  end

  it 'is the order they were written, on the set list' do
    assert_equal @set_ids, sets_listed_on("/workouts/#{@workout_id}/sets")
  end

  # The record groups by movement, so the assertion is per card: squat's three in ramp
  # order, then bench's two. Sorting by exercise_id left these interleaved however the
  # database felt, which on a barbell session means a working set above its own warmup.
  it 'is the order they were written, within each card of the record' do
    assert_equal @set_ids, sets_listed_on("/workouts/#{@workout_id}")
  end

  # The cards themselves. exercise_id order is the order the movements were added to the
  # exercises table, which has nothing to do with this session: here the bench row is the
  # older of the two, so sorting by it put bench above squat on a session that opened with
  # squats.
  it 'puts the cards in the order the lifts were first performed' do
    get "/workouts/#{@workout_id}"

    assert_operator last_response.body.index(@squat_name), :<, last_response.body.index(@bench_name),
                    'the squat card should come first, because the squats were lifted first'
  end

  # The association itself, rather than a page that uses it. This is where the missing
  # :order actually was, and anything else reaching for workout.sets gets it too.
  it 'is the order they were written, on the association' do
    workout = Tectonic::Workout[@workout_id]

    assert_equal @set_ids, workout.sets.map(&:id)
  end
end

