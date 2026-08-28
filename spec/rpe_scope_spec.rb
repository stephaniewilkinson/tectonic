# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/measured'

# Where an RPE may sit at all. #211.
#
# RPE is reps in reserve: an 8 says two more were there. A held position has no reps for
# any to be spare of, and the scale the app prints is written entirely in rep counts --
# "4+", "3", "2", "1", "0" -- so on a timed set it explained a measure that could not be
# applied to it. A warmup is submaximal by definition, so its rating is a number nobody
# reads back.
#
# The rule was in one view and nowhere else: the session screen declined to ask a warmup,
# but only by which list the row was rendered in, and it asked every timed working set.
# No write path refused a rating at all. It is now said once on the model, enforced by the
# tools with a sentence a caller can act on, and enforced again by the database, which is
# the only one of the three that cannot be routed around.
module RpeScope
  def app
    Tectonic.app
  end

  def timed = Tectonic::Measured.stored(Tectonic::Measured::TIME)

  # A workout and a movement to hang a row on, for the tests that write straight to the
  # table rather than through a page.
  def scratch_lift
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    [DB[:workouts].insert(account_id:, date: Time.now),
     DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)]
  end

  # A session holding one of each kind of set, so a single render can be asked which of
  # them were offered a rating.
  def mixed_session(account_id)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, is_barbell: true, is_completed: false }
    DB[:sets].insert(**common, weight: 45, reps: 5, is_warmup: true)
    working = DB[:sets].insert(**common, weight: 155, reps: 5, is_warmup: false)
    held = DB[:sets].insert(**common, weight: nil, reps: nil, duration_seconds: 60,
                                      measure: timed, is_warmup: false, is_barbell: false)
    [workout_id, working, held]
  end
end

describe 'which sets the session screen asks to rate' do
  include Rack::Test::Methods
  include RouteOwnership
  include RpeScope

  before do
    @account_id = login
    @workout_id, @working, @held = mixed_session(@account_id)
    get "/workouts/#{@workout_id}/session"
    @body = last_response.body
  end

  # A set is offered a rating when one of its forms carries a name="rpe" button. Every form
  # on a set posts to the same complete path -- Done, the revision, and the ratings -- so
  # this has to look at all of them rather than at the first, which is Done and never
  # carries one.
  def rating_form?(set_id)
    @body.scan(%r{<form[^>]*action="[^"]*/sets/#{set_id}/complete"[^>]*>.*?</form>}m)
         .any? { |form| form.include?('name="rpe"') }
  end

  it 'asks a working set counted in reps' do
    assert rating_form?(@working)
  end

  # The one that was wrong: a plank got the same five buttons as a squat.
  it 'does not ask a set counted in seconds' do
    refute rating_form?(@held)
  end

  it 'still shows the scale, because one set on the panel can be rated' do
    assert_includes @body, 'How do I rate this?'
  end
end

# A lift of nothing but timed sets asks nothing, so the table explaining a rep-count scale
# has no business under it. Until #211 this was only true of a warmup-only lift.
describe 'the rating scale on a lift measured in seconds' do
  include Rack::Test::Methods
  include RouteOwnership
  include RpeScope

  it 'is not drawn at all' do
    account_id = login
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Plank #{SecureRandom.hex(4)}", account_id:)
    2.times do
      DB[:sets].insert(workout_id:, exercise_id:, weight: nil, reps: nil, duration_seconds: 60,
                       measure: timed, is_warmup: false, is_completed: false, is_barbell: false)
    end
    get "/workouts/#{workout_id}/session"

    refute_includes last_response.body, 'How do I rate this?'
    refute_includes last_response.body, 'name="rpe"'
  end
end

describe 'the database refusal' do
  include RpeScope

  # The backstop. The tools refuse first and say why; this is what holds if anything ever
  # writes the column without going through one.
  it 'refuses a rating on a warmup' do
    workout_id, exercise_id = scratch_lift

    assert_raises(Sequel::CheckConstraintViolation) do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 45, reps: 5,
                       is_warmup: true, is_completed: true, rpe: 8)
    end
  end

  it 'refuses a rating on a set counted in seconds' do
    workout_id, exercise_id = scratch_lift

    assert_raises(Sequel::CheckConstraintViolation) do
      DB[:sets].insert(workout_id:, exercise_id:, duration_seconds: 60, measure: timed,
                       is_warmup: false, is_completed: true, rpe: 8)
    end
  end

  it 'still allows one on a working set counted in reps' do
    workout_id, exercise_id = scratch_lift
    id = DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5,
                          is_warmup: false, is_completed: true, rpe: 8)

    assert_equal 8, DB[:sets].where(id:).get(:rpe)
  end
end

module RpeScopeSets
  def a_set(account_id, **over)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert({ workout_id:, exercise_id:, weight: 155, reps: 5,
                       is_warmup: false, is_completed: false }.merge(over))
  end
end

describe 'what the MCP tools say about a rating that does not apply' do
  include Rack::Test::Methods
  include RpeScopeSets

  # Refused by name rather than by constraint violation: a database error reaches a client
  # as the tool being broken, where this is something a model can act on.
  it 'refuses to rate a warmup, and says why' do
    token = mint(scopes: %w[read write])
    set_id = a_set(token.account_id, is_warmup: true)
    call_tool('complete_set', raw: token.raw, arguments: { set_id:, rpe: 8 })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'reps in reserve'
    assert_nil DB[:sets].where(id: set_id).get(:rpe)
  end

  it 'refuses to rate a set counted in seconds' do
    token = mint(scopes: %w[read write])
    set_id = a_set(token.account_id, weight: nil, reps: nil, duration_seconds: 60,
                                     measure: Tectonic::Measured.stored(Tectonic::Measured::TIME))
    call_tool('complete_set', raw: token.raw, arguments: { set_id:, rpe: 8 })

    assert tool_result['isError']
    assert_nil DB[:sets].where(id: set_id).get(:rpe)
  end

  it 'still records a rating on a working set counted in reps' do
    token = mint(scopes: %w[read write])
    set_id = a_set(token.account_id)
    call_tool('complete_set', raw: token.raw, arguments: { set_id:, rpe: 8 })

    refute tool_result['isError']
    assert_equal 8, DB[:sets].where(id: set_id).get(:rpe)
  end
end

# update_set is the one tool that can move is_warmup and rpe in a single call, so the shape
# it checks has to be the one the set is being left in rather than the one it is in now.
# Both directions of that are reachable and neither is caught by looking at the row as it
# stands.
describe 'a rating and a warmup flag moving in the same call' do
  include Rack::Test::Methods
  include RpeScopeSets

  it 'refuses a rating on a set the same call is making a warmup' do
    token = mint(scopes: %w[read write])
    set_id = a_set(token.account_id)
    call_tool('update_set', raw: token.raw, arguments: { set_id:, rpe: 8, is_warmup: true })

    assert tool_result['isError']
    assert_nil DB[:sets].where(id: set_id).get(:rpe)
    refute DB[:sets].where(id: set_id).get(:is_warmup), 'and should not have made it a warmup either'
  end

  # The other direction of the same trap: a set that already carries a rating being turned
  # into a warmup would leave the row in a shape the constraint refuses.
  it 'refuses to make a rated set a warmup' do
    token = mint(scopes: %w[read write])
    set_id = a_set(token.account_id, rpe: 8, is_completed: true)
    call_tool('update_set', raw: token.raw, arguments: { set_id:, is_warmup: true })

    assert tool_result['isError']
    refute DB[:sets].where(id: set_id).get(:is_warmup)
  end
end

