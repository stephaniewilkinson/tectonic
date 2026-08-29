# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# Three complaints about the same thing: the app not saying what it means about how a
# movement is done.
#
# #280 -- a set read "20 × 8", and "3 x 8" means three sets of eight everywhere lifting is
# written down. On a heavy barbell lift the size of the number settles it, since nobody
# does 225 sets. On the accessory work where the first number is small, nothing did.
#
# #278 -- the rating scale was offered on work carrying no load, where it asks a question
# about a movement rather than about a weight, and where the answer moves nothing.
#
# #279 -- the exercise form could not say a movement is counted per side, though every
# other write path could, so a split squat added in the browser counted half its volume.
module SetMeaning
  def a_set(account_id, **columns)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id:, exercise_id:, is_warmup: false, is_completed: false, **columns)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # The five rating buttons, which are the thing #278 is about offering or not.
  def rating_buttons(body)
    body.scan(/<button[^>]*name="rpe"[^>]*>\s*(\d+)/).flatten
  end
end

describe 'what a loaded set says it is' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetMeaning

  # The unit, on the number that is already the largest thing on the row. Three characters
  # to settle a phrase that a lifter reads as sets-and-reps.
  it 'names the pounds, so the two numbers cannot read as sets and reps' do
    body = a_set(login, weight: 20, reps: 8, is_barbell: false)

    assert_includes body, '20 lb × 8'
    refute_match(/>\s*20 × 8/, body)
  end

  it 'says it for a heavy barbell set too, where the size of the number already said it' do
    body = a_set(login, weight: 225, reps: 5, is_barbell: true)

    assert_includes body, '225 lb × 5'
  end

  # A half is not a rounding artefact here: it is what a pair of 2.5s makes.
  it 'keeps a half-pound load a half rather than dressing it up' do
    body = a_set(login, weight: 137.5, reps: 3, is_barbell: true)

    assert_includes body, '137.5 lb × 3'
  end
end

describe 'what a set carrying no load says it is' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetMeaning

  # No load in front of the count, so the count says what it is in full rather than
  # borrowing the clarity of a weight that is not there.
  it 'says the reps in words, and no pounds it does not have' do
    body = a_set(login, weight: nil, reps: 8)

    assert_includes body, '8 reps'
    refute_includes body, 'lb ×'
  end

  it 'says the seconds for work that is held rather than counted' do
    body = a_set(login, weight: nil, reps: nil, duration_seconds: 60, measure: 'time')

    assert_includes body, '60s'
  end

  # The count is written as one side and lifted as two, which is the whole reason the
  # column exists: counted_reps doubles it and every volume figure depends on the answer.
  it 'says when a count is per side' do
    body = a_set(login, weight: 20, reps: 8, is_per_side: true)

    assert_includes body, 'per side'
  end
end

# #278. The scale is five 48px buttons, which is the tallest thing on a row, and on a
# session of banded and bodyweight accessories it was most of the screen -- asking, every
# time, a question whose answer sits beside a blank where every other rated set has a
# number, and which Progression has no weight to step.
describe 'which sets are asked for a rating' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetMeaning

  it 'asks on a working set that has a load' do
    body = a_set(login, weight: 155, reps: 5)

    assert_equal %w[6 7 8 9 10], rating_buttons(body)
  end

  it 'does not ask on work carrying no load at all' do
    body = a_set(login, weight: nil, reps: 12)

    assert_empty rating_buttons(body)
  end

  # The two rules #211 settled, which have not changed: a warmup is submaximal by
  # definition, and a held position has no reps for any to be in reserve of.
  it 'still does not ask on a warmup or on timed work' do
    warmup = a_set(login, weight: 95, reps: 5, is_warmup: true)
    timed = a_set(login, weight: 45, reps: nil, duration_seconds: 60, measure: 'time')

    assert_empty rating_buttons(warmup)
    assert_empty rating_buttons(timed)
  end
end

# #279. The column has existed since the per-side work and every write path could set it
# except the one a person actually uses.
describe 'the exercise form and how a movement is counted' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @account_id = login }

  def submit(fields)
    get '/exercises/new'
    post '/exercises', { '_csrf' => token_from(last_response.body), 'id' => '', **fields }
  end

  it 'offers the question' do
    get '/exercises/new'

    assert_includes last_response.body, 'name="default_is_per_side"'
    assert_includes last_response.body, 'Counted per side'
  end

  it 'writes the answer' do
    submit('name' => "Split Squat #{SecureRandom.hex(4)}", 'default_is_per_side' => '1')

    assert_predicate Tectonic::Exercise.where(account_id: @account_id).first, :default_is_per_side
  end
end

describe 'editing how a movement is counted' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    @name = "Split Squat #{SecureRandom.hex(4)}"
    get '/exercises/new'
    post '/exercises', { '_csrf' => token_from(last_response.body), 'id' => '',
                         'name' => @name, 'default_is_per_side' => '1' }
    @exercise = Tectonic::Exercise.where(account_id: @account_id, name: @name).first
    get "/exercises/#{@exercise.id}/edit"
  end

  it 'comes back ticked in the form it was saved from' do
    assert_match(/id="default_is_per_side"[^>]*\n?\s*checked/, last_response.body)
  end

  # A checkbox posts nothing when it is clear, so "not ticked" has to be a write of false
  # rather than an absence that leaves whatever was there before.
  it 'takes the answer away again when the box is cleared' do
    post '/exercises', { '_csrf' => token_from(last_response.body),
                         'id' => @exercise.id.to_s, 'name' => @name }

    refute_predicate @exercise.refresh, :default_is_per_side
  end
end

