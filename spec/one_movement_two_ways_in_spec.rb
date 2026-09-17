# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec'           # reuses its token minting and call_tool; idempotent require
require_relative 'two_dumbbells_spec' # and its shelf, block and generation helpers
require 'securerandom'

# The fields the exercise form offers and `update_exercise` did not. #454.
#
# The tool's own comment said the two ways in "change the same things and no more", naming
# that as the point. It had quietly stopped being true: the form offers `default_is_per_side`
# (#279), `dumbbell_count` (#439) and `default_rest_seconds` (#456), and the tool offered none
# of the three -- so a lifter could say how many dumbbells a movement takes and an assistant
# could not, on the one question that decides which weights exist for it at all.
#
# Two of the three reach past the row they edit, and the consequences come with them rather
# than after them. A tool that set the column and skipped the rewrite would leave the sessions
# saying one thing and the movement another, which is the staleness #465 fixed on the rack side.
module TwoWaysIn
  def a_movement(account_id, **attributes)
    Tectonic::Exercise.create(name: "Single-Leg DB RDL #{SecureRandom.hex(4)}",
                              account_id:, is_barbell: false, **attributes)
  end

  def edit(raw, exercise, **arguments)
    call_tool('update_exercise', raw:, arguments: { exercise_id: exercise.id, **arguments })
  end

  def stored(exercise, field) = DB[:exercises].where(id: exercise.id).get(field)
end

describe 'the three fields the form had and the tool did not' do
  include Rack::Test::Methods
  include TwoWaysIn

  before { @token = mint(scopes: %w[read write]) }

  it 'sets how many dumbbells a movement takes' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, dumbbell_count: 1)

    assert_equal 1, stored(exercise, :dumbbell_count)
  end

  # Null is a real answer and has to stay sayable: it is the difference between "nobody has
  # said" and "deliberately two", and the whole reason the column is nullable.
  it 'puts the count back to nobody having said' do
    exercise = a_movement(@token.account_id, dumbbell_count: 2)
    edit(@token.raw, exercise, dumbbell_count: nil)

    assert_nil stored(exercise, :dumbbell_count)
  end

  it 'sets whether the reps are counted per side' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, default_is_per_side: true)

    assert stored(exercise, :default_is_per_side)
  end

  # Read through Rest rather than off the row: 039 moved it onto (account, movement), so a
  # library Back Squat can carry one. See the_bell_belongs_to_the_lifter_spec.
  it 'sets how long the movement is rested' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, default_rest_seconds: 180)

    assert_equal 180, Tectonic::Rest.for(account_id: @token.account_id, exercise_id: exercise.id)
  end
end

# Cleaned by the same rules the browser form posts into, rather than written at the column, so
# a value set by a person and one set by an assistant cannot be cleaned two different ways.
describe 'a value the column would refuse' do
  include Rack::Test::Methods
  include TwoWaysIn

  before { @token = mint(scopes: %w[read write]) }

  # Refused rather than clamped, on the cleaner's own terms: clamping 9000 to 1800 would store
  # a number nobody asked for and then ring at them for half an hour of it.
  it 'refuses a rest nobody would take rather than clamping it' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, default_rest_seconds: 9000)

    assert_nil Tectonic::Rest.for(account_id: @token.account_id, exercise_id: exercise.id)
  end

  # A missing key means "leave it" where a key holding null means "clear it". Renaming a
  # movement must not wipe the three fields the caller said nothing about.
  it 'leaves a field the caller did not mention' do
    exercise = a_movement(@token.account_id, dumbbell_count: 1)
    Tectonic::Rest.replace(@token.account_id, exercise.id, 120)
    edit(@token.raw, exercise, name: "Renamed #{SecureRandom.hex(4)}")

    assert_equal 1, stored(exercise, :dumbbell_count)
    assert_equal 120, Tectonic::Rest.for(account_id: @token.account_id, exercise_id: exercise.id)
  end
end

# The half that makes two of these different in kind from a rename.
describe 'an edit that reaches past the row it edits' do
  include Rack::Test::Methods
  include TwoWaysIn

  before { @token = mint(scopes: %w[read write]) }

  def a_logged_set(exercise, reps: 8)
    workout_id = DB[:workouts].insert(account_id: @token.account_id, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 39, reps:,
                     is_warmup: false, is_completed: true, is_barbell: false, is_per_side: false)
  end

  # Saying a movement is counted per side is a statement about the movement rather than about
  # today, so the sets that were following the old answer follow the new one (#392) -- and the
  # tool says how many, because it has just rewritten logged training.
  it 'recounts the sets that were following the old answer' do
    exercise = a_movement(@token.account_id)
    2.times { a_logged_set(exercise) }
    edit(@token.raw, exercise, default_is_per_side: true)

    assert_equal 2, tool_result.dig('structuredContent', 'sets_recounted')
  end

  it 'says so in the sentence rather than only in the payload' do
    exercise = a_movement(@token.account_id)
    a_logged_set(exercise)
    edit(@token.raw, exercise, default_is_per_side: true)

    assert_includes tool_result.dig('content', 0, 'text'), 'recounted'
  end
end

# And the edits that reach nowhere, which have to say nothing rather than say zero.
describe 'an edit with no consequences to report' do
  include Rack::Test::Methods
  include TwoWaysIn

  before { @token = mint(scopes: %w[read write]) }

  # Filling a blank in as two is what the app was already assuming, so it is not a change and
  # must rewrite nothing. Compared on `dumbbells` rather than on the column, which is the only
  # way to tell those two apart.
  it 'rewrites nothing where the answer was already what was assumed' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, dumbbell_count: 2)

    assert_equal 0, tool_result.dig('structuredContent', 'sessions_rerounded')
  end

  # A rename reporting "0 sessions rewritten" would read as though it had considered
  # rewriting some.
  it 'stays quiet about consequences a rename cannot have' do
    exercise = a_movement(@token.account_id)
    edit(@token.raw, exercise, name: "Renamed #{SecureRandom.hex(4)}")

    refute_includes tool_result.dig('content', 0, 'text'), 'rewritten'
    refute_includes tool_result.dig('content', 0, 'text'), 'recounted'
  end
end

# The case the whole thing is for, against the reporting account's real shelf: a 4 lb handle
# with pairs of 10, 5 and 2.5, and a movement prescribed at 45.
#
# A pair tops out at 39, so 45 floors to the ceiling of the shelf. One dumbbell reaches 79, so
# the same 45 lands on 44. Saying how many therefore has to reach the session already written,
# or the movement and the sessions disagree about what can be loaded.
describe 'a count that moves a session already written' do
  include Rack::Test::Methods
  include TwoWaysIn
  include TwoDumbbells

  before do
    @token = mint(scopes: %w[read write])
    the_reported_shelf(@token.account_id)
    # TwoDumbbells' own a_movement, which takes the count outright; nil is the unanswered
    # state under test, where the generator falls back to Equipment::DEFAULT_DUMBBELLS.
    @exercise = a_movement(@token.account_id, dumbbell_count: nil)
    @written = a_block(@token.account_id, @exercise, top_weight: 45)
  end

  it 'writes the session against the assumed pair to begin with' do
    assert_equal [39, 39], @written
  end

  def weights_now
    Tectonic::WorkoutSet.where(exercise_id: @exercise.id).exclude(is_warmup: true).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }
  end

  it 'rewrites it onto what one dumbbell can load' do
    edit(@token.raw, @exercise, dumbbell_count: 1)

    assert_equal [44, 44], weights_now
  end

  it 'reports the session it rewrote rather than doing it silently' do
    edit(@token.raw, @exercise, dumbbell_count: 1)

    assert_equal 1, tool_result.dig('structuredContent', 'sessions_rerounded')
    assert_includes tool_result.dig('content', 0, 'text'), 'rewritten onto weights it can load'
  end
end

