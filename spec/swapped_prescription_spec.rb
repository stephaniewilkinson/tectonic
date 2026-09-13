# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require 'securerandom'

# A prescription belongs to the movement it was written for. #406.
#
# Two generated Barbell Hip Thrust sets at 85 lb were swapped to bodyweight Single-Leg Hip
# Thrust, and the session read:
#
#   Single-Leg Hip Thrust 10 reps per side   (planned 85x8)
#
# A bodyweight movement supposedly prescribed at 85 lb. The planned columns said what the
# *other* lift was asked for and nothing cleared them, so the only remedy was deleting both
# sets and creating replacements -- which then carry no prescription at all.
#
# The planned_ columns are otherwise one of the best things in the app: `135x5 (planned
# 122x5)` is what makes a deviation readable, and it is the input for the next block's
# training maxes. That is exactly why a wrong value is worse than none.
#
# Three paths move a set onto another movement and all three had this, which is why the rule
# is now on the model rather than at any of them.
module SwappedPrescription
  def movement(account_id, name: nil, barbell: true)
    Tectonic::Exercise.create(name: name || "Lift #{SecureRandom.hex(4)}", account_id:,
                              is_barbell: barbell)
  end

  # A generated set, carrying the full prescription the generator writes.
  def prescribed_set(workout_id, exercise, **overrides)
    DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 85, reps: 8,
                       is_warmup: false, is_completed: false, is_barbell: true,
                       planned_weight: 85, planned_reps: 8, planned_rpe: 8,
                       planned_rest_seconds: 180 }.merge(overrides))
  end

  def planned_of(set_id)
    DB[:sets].where(id: set_id).select(:planned_weight, :planned_reps, :planned_rpe,
                                       :planned_rest_seconds).first
  end

  def still_prescribed?(set_id) = planned_of(set_id).values.any?
end

describe 'swapping one set onto another movement' do
  include Rack::Test::Methods
  include SwappedPrescription

  before do
    @raw = mint(scopes: %w[read write]).raw
    @account_id = DB[:oauth_grants].order(:id).last[:account_id]
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now)
    @into = movement(@account_id, name: "Single-Leg Hip Thrust #{SecureRandom.hex(4)}", barbell: false)
    @set_id = prescribed_set(@workout_id, movement(@account_id))
  end

  def swap
    call_tool('update_set', raw: @raw, arguments: { set_id: @set_id, exercise: @into.name })
  end

  it 'leaves no prescription from the movement it used to be' do
    swap

    refute still_prescribed?(@set_id), 'the old lift\'s prescription is still on the row'
  end

  # Each of the four columns is a separate answer to "what was this lift asked for", and a
  # fix that cleared three of them would read as fixed and still print a wrong number.
  it 'clears every one of them, not only the weight' do
    swap
    planned = planned_of(@set_id)

    assert_nil planned[:planned_weight]
    assert_nil planned[:planned_reps]
    assert_nil planned[:planned_rpe]
    assert_nil planned[:planned_rest_seconds]
  end
end

# The rule that was already right at all three call sites, and has to survive the move onto
# the model: plate math describing the movement that was swapped out is worse than none.
describe 'what a swapped set keeps' do
  include Rack::Test::Methods
  include SwappedPrescription

  it 'takes the new movement\'s barbell flag with it' do
    raw = mint(scopes: %w[read write]).raw
    account_id = DB[:oauth_grants].order(:id).last[:account_id]
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    into = movement(account_id, barbell: false)
    set_id = prescribed_set(workout_id, movement(account_id))
    call_tool('update_set', raw:, arguments: { set_id:, exercise: into.name })

    refute DB[:sets].where(id: set_id).get(:is_barbell)
  end
end

# Clearing has to fire on a swap and only on a swap. A rule that cleared more widely would
# destroy the readings the planned_ columns exist for, which is the opposite of the fix.
describe 'a change to a set that is not a swap' do
  include Rack::Test::Methods
  include SwappedPrescription

  before do
    @raw = mint(scopes: %w[read write]).raw
    @account_id = DB[:oauth_grants].order(:id).last[:account_id]
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now)
    @set_id = prescribed_set(@workout_id, movement(@account_id))
  end

  # Re-sending the movement a set is already on is not a swap. Without this an assistant
  # echoing back the row it just read would wipe a prescription it never meant to touch.
  it 'leaves a set alone when the exercise named is the one it already has' do
    same = DB[:exercises].where(id: DB[:sets].where(id: @set_id).get(:exercise_id)).get(:name)
    call_tool('update_set', raw: @raw, arguments: { set_id: @set_id, exercise: same })

    assert still_prescribed?(@set_id)
  end

  # A correction that is not a swap must not clear anything either -- fixing the weight two
  # reps in is the case #215 exists for, and the prescription is what it is measured against.
  it 'leaves the prescription alone when only the weight is corrected' do
    call_tool('update_set', raw: @raw, arguments: { set_id: @set_id, weight: 95 })

    assert_equal 85, planned_of(@set_id)[:planned_weight]
  end
end

describe 'swapping a whole movement in a session over MCP' do
  include Rack::Test::Methods
  include SwappedPrescription

  it 'clears the prescription on every set it moves' do
    raw = mint(scopes: %w[read write]).raw
    account_id = DB[:oauth_grants].order(:id).last[:account_id]
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    from = movement(account_id)
    into = movement(account_id, barbell: false)
    sets = Array.new(2) { prescribed_set(workout_id, from) }
    call_tool('update_workout_exercise', raw:,
                                         arguments: { workout_id:, from_exercise: from.name,
                                                      to_exercise: into.name })

    sets.each { |id| refute still_prescribed?(id), "set #{id} kept the old prescription" }
  end
end

describe 'swapping a movement from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SwappedPrescription

  # The web path only ever moves unlifted sets, so a completed one is not its concern -- but
  # the sets it does move are exactly the generated ones this issue is about.
  it 'clears the prescription on the sets it moves' do
    account_id = login
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    from = movement(account_id)
    into = movement(account_id, barbell: false)
    set_id = prescribed_set(workout_id, from)
    path = "/workouts/#{workout_id}/session/swap"
    post path, { 'from_exercise_id' => from.id.to_s, 'exercise_id' => into.id.to_s,
                 '_csrf' => token_for_form("/workouts/#{workout_id}/session", path) }

    refute still_prescribed?(set_id)
  end
end

