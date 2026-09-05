# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #365's browser half: swapping the movement a whole lift is on, in one tap.
#
# The MCP side is update_workout_exercise and is specced in mcp_exercise_swap_spec. Both
# draw the same line, and it is #364's: a set already marked as lifted records a movement
# that was performed, so it does not move. What is asserted here is that the route in front
# of the session screen draws it in the same place the tool does -- two paths that disagreed
# about what a swap may touch would be worse than either rule on its own.
module SessionSwap
  # A lift of three sets, some of them already lifted, plus a second movement to swap onto.
  # The two differ in is_barbell so the flag has something to be wrong about after a move.
  def lift_of(completed: 0)
    account_id = login
    workout_id = own_workout(account_id)
    from = movement(account_id, 'Dumbbell Overhead Press', barbell: false)
    3.times { |index| logged_set(workout_id, from, done: index < completed) }
    [workout_id, from, movement(account_id, 'Barbell Overhead Press', barbell: true)]
  end

  def movement(account_id, name, barbell:)
    DB[:exercises].insert(name: "#{name} #{SecureRandom.hex(4)}", account_id:, is_barbell: barbell)
  end

  def logged_set(workout_id, exercise_id, done:)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 65, reps: 5, is_barbell: false,
                     is_warmup: false, **Tectonic::WorkoutSet.completion(done))
  end

  def swap(workout_id, from, into)
    action = "/workouts/#{workout_id}/session/swap"
    post action, { '_csrf' => token_for_form("/workouts/#{workout_id}/session", action),
                   'from_exercise_id' => from, 'exercise_id' => into }
  end

  def movements_on(workout_id)
    DB[:sets].where(workout_id:).order(:id).select_map(%i[exercise_id is_completed])
  end
end

describe 'swapping a lift from the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionSwap

  it 'moves every unlifted set in one post' do
    workout_id, from, into = lift_of
    swap(workout_id, from, into)

    assert_equal [[into, false]] * 3, movements_on(workout_id)
  end

  # The movement being swapped onto is a barbell lift and the one being swapped off is not,
  # so the flag has to travel or the plate line would describe the movement that left.
  it 'takes the new plate math with it' do
    workout_id, from, into = lift_of
    swap(workout_id, from, into)

    assert_equal [true] * 3, DB[:sets].where(workout_id:).select_map(:is_barbell)
  end

  # #364, drawn in the WHERE clause rather than in a guard, which is what keeps this route
  # and update_workout_exercise from drifting apart.
  it 'leaves sets already marked as lifted where they are' do
    workout_id, from, into = lift_of(completed: 2)
    swap(workout_id, from, into)

    assert_equal [[from, true], [from, true], [into, false]], movements_on(workout_id)
  end

  it 'changes nothing when the lift is already on that movement' do
    workout_id, from, = lift_of
    swap(workout_id, from, from)

    assert_equal [[from, false]] * 3, movements_on(workout_id)
  end
end

describe 'the swap control on the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionSwap

  def session_body(workout_id)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  it 'offers the swap while sets are still unlifted, and says how many will move' do
    workout_id, = lift_of(completed: 1)
    body = session_body(workout_id)

    assert_includes body, 'Lifted a different movement'
    assert_includes body, 'Swap 2 remaining sets for'
  end

  # A lift with nothing left to move could only offer a control that does nothing, and a
  # dead control on a screen read at arm's length is worse than no control.
  it 'is absent once every set of the lift is lifted' do
    workout_id, = lift_of(completed: 3)

    refute_includes session_body(workout_id), 'Lifted a different movement'
  end

  it 'counts a single remaining set in the singular' do
    workout_id, = lift_of(completed: 2)

    assert_includes session_body(workout_id), 'Swap 1 remaining set for'
  end
end

describe 'swapping a lift in a session that is not yours' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionSwap

  # The ownership gate every nested workout route sits behind. Asserted here because this
  # route writes to sets by exercise_id rather than by set id, which is the shape most
  # likely to reach rows it was never handed.
  #
  # The token is lifted from the owner's own page before the account changes, which is the
  # strongest form of the attack this can express: a real token for the real action, sent by
  # somebody else. It is refused twice over -- the session it was minted against is gone,
  # and the workout does not resolve for the account now asking -- and the assertion is
  # simply that nothing moved.
  it 'never reaches another account' do
    workout_id, from, into = lift_of
    action = "/workouts/#{workout_id}/session/swap"
    token = token_for_form("/workouts/#{workout_id}/session", action)
    before = movements_on(workout_id)
    login # a second account, which replaces the session the first one left
    post action, { '_csrf' => token, 'from_exercise_id' => from, 'exercise_id' => into }

    assert_equal before, movements_on(workout_id)
  end
end

