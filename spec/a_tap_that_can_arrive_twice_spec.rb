# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'session_timing_spec'  # and its scratch session, stamp_of and done? helpers

# Stage zero of #542, and the half of it that has to be right even if nothing else ships.
#
# The queue that issue asks for is a list of taps to be sent again later, so the question it
# puts to this route is not "what does one tap mean" but "what does the same tap mean the
# second time". #516 answered that and stopped: the primary Done tap toggles, deliberately,
# so a mis-tap is undone by tapping again -- and a replayed tap therefore marks the set done
# and then un-does it. A queue built on that would turn a set the lifter did into a set the
# app says they did not, minutes later, with nothing on the screen to say so. That is worse
# than the bug it was fixing.
#
# There is a deeper form of the same problem, which is why this is not a fix at the queue
# layer. A queue of toggles is a queue of instructions whose meaning depends on the server's
# state when they arrive, and by then the fifteen-second poll or an assistant writing over
# MCP may have changed it. "Flip it" cannot be made safe to repeat by any amount of care on
# the phone. "Make it done" can, and is safe to repeat by construction.
#
# So a tap says what state it wants, and a tap whose state has already been reached does
# nothing at all -- not even to the stamp, which is the part that would otherwise rot
# quietly: re-stamping completed_at on a set that was already done moves a turnaround the
# lifter never took, which is the same objection the correction path has always made.
#
# Rack::Test, because all of this is a route and a column. What a lifter sees while a tap is
# held is in losing_signal_browser_spec.rb.
module ArrivingTwice
  # A warmup and a working set, because the Done button is the same button on both rows and
  # a ramp step tapped off with no signal is exactly as lost as a working set.
  def a_session(account_id)
    @workout_id, exercise_id = scratch_workout(account_id)
    @warmup_id = written_set(@workout_id, exercise_id, is_warmup: true)
    @set_id = written_set(@workout_id, exercise_id)
    @workout_id
  end

  # A post to the completion route, made the way the session screen's form makes it.
  def tap(**fields)
    action = "/workouts/#{@workout_id}/sets/#{@set_id}/complete"
    token = token_for_form("/workouts/#{@workout_id}/session", action)
    post action, fields.transform_keys(&:to_s).merge('_csrf' => token), { 'HTTP_HX_REQUEST' => 'true' }
  end

  def finished? = done?(@set_id)
  def stamp = stamp_of(@set_id)

  # What a queued tap carries: the moment it was made, in milliseconds, which is what
  # Date.now() hands a script on the phone.
  def millis(time) = (time.to_f * 1000).round
end

describe 'a Done tap that says which state it is asking for' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  it 'completes the set' do
    tap(is_completed: 'true')

    assert finished?
  end

  # The whole of stage zero. Before this the second one un-did the first.
  it 'leaves it completed when the same tap arrives again' do
    tap(is_completed: 'true')
    tap(is_completed: 'true')

    assert finished?, 'a replayed tap must not undo the set it recorded'
  end

  # And the quieter half. A set that is already done is not done again, so the instant it
  # was done is not a fact a second arrival gets to revise -- a re-stamp would move the
  # turnaround Timing reads between this set and the one before it.
  it 'does not move the stamp the first one wrote' do
    tap(is_completed: 'true')
    first = stamp
    tap(is_completed: 'true')

    assert_equal first, stamp
  end
end

# The other direction, which the same field carries: Undo is the same button having
# rendered the other word, so it is the same request saying the other state.
describe 'an Undo tap' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before do
    a_session(login)
    tap(is_completed: 'true')
  end

  it 'un-completes the set' do
    tap(is_completed: 'false')

    refute finished?
    assert_nil stamp, 'a set that was not done cannot carry the instant it was done'
  end

  it 'leaves it undone when it arrives again' do
    tap(is_completed: 'false')
    tap(is_completed: 'false')

    refute finished?
  end
end

describe 'a Done tap that says nothing about the state it wants' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # The fallback, kept rather than tolerated. With JavaScript off there is no htmx either,
  # so Done is a plain form post -- and the form is rendered from the row, so it says what
  # it is asking for. What cannot say is anything posting to this route by hand, and a
  # toggle is the reading that matches the button's own word for what it does.
  it 'toggles, which is what it has always done' do
    tap

    assert finished?

    tap

    refute finished?
  end

  # A value this route does not recognise is a request that said nothing it understands,
  # and guessing between "done" and "not done" from a word nobody defined is how a set
  # comes to be un-done by a typo. It falls back to the behaviour above.
  it 'toggles for a word it does not know' do
    tap(is_completed: 'perhaps')

    assert finished?
  end
end

describe 'a rating that arrives twice' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # Rating a set completes it, because choosing an RPE is saying you lifted it. That path
  # was already absolute rather than a toggle, so it survived a replay -- but it re-stamped
  # every time, which #516 named as the subtler wrinkle: correct on replay, not honest on
  # replay. It is the same rule as above and it falls out of the same fix.
  it 'does not move the stamp of a set that was already done' do
    tap(is_completed: 'true')
    first = stamp
    tap(rpe: '8')

    assert_equal first, stamp
    assert_equal 8, DB[:sets].where(id: @set_id).get(:rpe)
  end

  it 'still completes a set that was not done' do
    tap(rpe: '8')

    assert finished?
    refute_nil stamp
  end
end

describe 'a correction that arrives twice' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # Unchanged by any of this, and asserted here because the branch it lives in was rewritten
  # around it. "The bar actually had 145 on it" is not "I have finished this set" (#215), so
  # a correction leaves the completion exactly as it was -- done or not -- however many times
  # it arrives.
  it 'writes what was typed and says nothing about the completion' do
    tap(weight: '145', reps: '5')
    tap(weight: '145', reps: '5')

    refute finished?
    assert_equal 145, DB[:sets].where(id: @set_id).get(:weight).to_i
  end
end

describe 'a tap that says when it happened' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # The reason a queue can exist at all without rewriting history. A set completed at 18:04
  # and sent at 18:40 happened at 18:04, and a stamp taken when the request arrives would
  # describe the phone finding signal rather than the lifter finishing a set -- which is the
  # distinction health data already draws between measured_at and created_at, for the same
  # reason and at the same cost of getting it wrong.
  it 'is stamped with the moment the tap was made rather than the moment it arrived' do
    made = Time.now - (36 * 60)
    tap(is_completed: 'true', completed_at: millis(made))

    assert_in_delta made.to_f, stamp.to_f, 1
  end

  # A phone's clock is the phone's, and it is wrong more often than anybody expects -- a
  # dead battery, a manual setting, a timezone typed in by hand. A completion in the future
  # is the one reading that is certainly untrue, and it is not harmless: it sorts above every
  # honest set and gives Timing a negative turnaround to explain.
  it 'refuses a stamp from the future and uses its own clock instead' do
    tap(is_completed: 'true', completed_at: millis(Time.now + (2 * 60 * 60)))

    assert_operator stamp, :<=, Time.now
    assert_in_delta Time.now.to_f, stamp.to_f, 5
  end
end

describe 'a tap whose account of when it happened cannot be believed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # The other end of the window. A queue holds a session's taps for minutes and survives a
  # tab being closed, so a day is generous; beyond it the likeliest explanation is a clock
  # that is wrong rather than a session that is still going, and the server's own answer is
  # the honest one -- the same thing create_set says about a session typed up in the evening.
  it 'falls back to the server clock for one older than a day' do
    tap(is_completed: 'true', completed_at: millis(Time.now - (30 * 60 * 60)))

    assert_in_delta Time.now.to_f, stamp.to_f, 5
  end

  it 'falls back for something that is not a moment at all' do
    tap(is_completed: 'true', completed_at: 'whenever')

    assert_in_delta Time.now.to_f, stamp.to_f, 5
  end

  # The stamp says when the set was done, and nothing else. An undo has no moment to place,
  # and a request that offered one alongside it would otherwise reach the check constraint
  # that refuses a set carrying the instant it was done without the completion to justify it.
  it 'is ignored entirely by an undo' do
    tap(is_completed: 'true')
    tap(is_completed: 'false', completed_at: millis(Time.now - 60))

    refute finished?
    assert_nil stamp
  end
end

describe 'the Done button on the session screen' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  # The one of the three forms posting to this set's completion route whose button carries
  # the given word, found by the label a screen reader hears rather than by the visible text,
  # which is wrapped across lines.
  def form_for(word)
    get "/workouts/#{@workout_id}/session"
    body = last_response.body.dup.force_encoding(Encoding::UTF_8)
    forms = body.scan(%r{<form[^>]*action="[^"]*/sets/#{@set_id}/complete"[^>]*>.*?</form>}m)
    forms.find { |form| form.include?(%(aria-label="#{word}:)) }
  end

  # The form is rendered from the row, so it already knows which of the two words it is
  # showing. Saying so in a hidden field is what turns the tap from an instruction into a
  # statement -- and it costs no query, which is what keeps the session page inside the
  # ceiling query_count_spec holds it to.
  it 'asks for the state the button says it will reach' do
    assert_includes form_for('Done'), 'name="is_completed" value="true"'
  end

  it 'asks for the other one once the set is done' do
    tap(is_completed: 'true')

    assert_includes form_for('Undo'), 'name="is_completed" value="false"'
  end

  # The revision and rating forms send no such field, and must not: what they mean by the
  # completion is decided by what else they carry, and a state on them would be a second
  # answer to a question they have already answered.
  it 'is on the Done form alone' do
    get "/workouts/#{@workout_id}/session"
    body = last_response.body.dup.force_encoding(Encoding::UTF_8)

    assert_equal 2, body.scan('name="is_completed"').length,
                 'one per row -- the warmup and the working set -- and none on the other forms'
  end
end

describe 'the set edit form, which was already explicit' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include ArrivingTwice

  before { a_session(login) }

  def save(**fields)
    path = "/workouts/#{@workout_id}/sets/#{@set_id}"
    token = token_for_form("/workouts/#{@workout_id}/sets/#{@set_id}/edit", path)
    post path, fields.transform_keys(&:to_s).merge('_csrf' => token)
  end

  # This form has sent an explicit state since long before any of this, which is where the
  # shape above came from rather than being invented for it. What it did not have was the
  # no-op: saving a corrected weight on a set that was already done re-stamped the
  # completion, so editing the load an hour later moved when the set was lifted.
  it 'keeps the stamp when the box was already ticked' do
    tap(is_completed: 'true')
    first = stamp
    save('weight' => '145', 'reps' => '5', 'is_completed' => 'on')

    assert_equal first, stamp
    assert_equal 145, DB[:sets].where(id: @set_id).get(:weight).to_i
  end

  it 'still clears both halves when the box is unticked' do
    tap(is_completed: 'true')
    save('weight' => '155', 'reps' => '5')

    refute finished?
    assert_nil stamp
  end
end

describe 'completing a set twice over MCP' do
  include Rack::Test::Methods
  include SessionTiming

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id, exercise_id = scratch_workout(@minted.account_id)
    @set_id = written_set(@workout_id, exercise_id)
  end

  # The same rule, reached from the other end. An assistant that logs a set it has already
  # logged is the ordinary shape of a retry, and it used to re-stamp -- which matters here
  # more than anywhere, because nothing is watching: the correction arrives in a session the
  # lifter finished hours ago.
  it 'does not move the stamp' do
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })
    first = stamp_of(@set_id)
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })

    assert_equal first, stamp_of(@set_id)
  end

  # And says so, rather than reporting a change it did not make. `changed` is what an
  # assistant reads back to the lifter.
  it 'reports that there was nothing to change' do
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })
    call_tool('complete_set', raw: @minted.raw, arguments: { set_id: @set_id })

    assert_includes tool_result.dig('content', 0, 'text'), 'nothing to change'
  end
end

