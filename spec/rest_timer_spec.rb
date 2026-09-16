# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'session_timing_spec'  # and its scratch_workout / written_set
require 'securerandom'

# The rest timer. #281.
#
# #281 first shipped as measurement and was reopened because none of it counts your rest: the
# header clock says how long you have been training, which between sets is not the number you
# want. This is the countdown, and what can be asserted from here is its server half -- the
# cue that arms it and the suggestion it offers. The counting itself is JavaScript and is
# pinned in spec/rest_timer_browser_spec.rb against a real Firefox, because a timer that does
# not tick is exactly the failure a rack_test assertion cannot see.
module RestTimer
  def tap_done(workout_id, set_id, fields = {})
    path = "/workouts/#{workout_id}/sets/#{set_id}/complete"
    post path,
         fields.merge('_csrf' => token_for_form("/workouts/#{workout_id}/session", path)),
         { 'HTTP_HX_REQUEST' => 'true' }
  end

  # The cue element's attributes, which is the whole of what the server tells the timer.
  def cue
    body = last_response.body
    { set: body[/id="rest-cue"[^>]*data-set="([^"]*)"/, 1],
      at: body[/id="rest-cue"[^>]*data-at="([^"]*)"/, 1],
      suggested: body[/id="rest-cue"[^>]*data-suggested="([^"]*)"/, 1],
      kind: body[/id="rest-cue"[^>]*data-kind="([^"]*)"/, 1],
      movement: body[/id="rest-cue"[^>]*data-movement="([^"]*)"/, 1] }
  end

  # A set carrying the rest its block prescribed, which is what the generator writes onto
  # every working set of a lift with a rest_seconds on it.
  def prescribed_set(workout_id, exercise_id, seconds)
    written_set(workout_id, exercise_id, planned_rest_seconds: seconds)
  end

  # A movement this account has trained before, with gaps of a known length between its sets
  # so the median is a number the spec can name. Three stamps two minutes apart is a median
  # turnaround of exactly 120 seconds.
  def history(account_id, exercise_id, gaps: [120, 120])
    workout_id = DB[:workouts].insert(account_id:, date: Time.now - 86_400)
    at = Time.now - 86_400
    written_set(workout_id, exercise_id, is_completed: true, completed_at: at)
    gaps.each do |gap|
      at += gap
      written_set(workout_id, exercise_id, is_completed: true, completed_at: at)
    end
    workout_id
  end
end

describe 'the session screen before anything is tapped' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    written_set(@workout_id, @exercise_id)
    get "/workouts/#{@workout_id}/session"
  end

  it 'carries the timer bar' do
    assert_includes last_response.body, 'id="rest-timer"'
  end

  # Arriving on a session whose last set was finished an hour ago must not open a countdown,
  # so the first paint carries no stamp for the script to act on.
  it 'cues nothing' do
    assert_empty cue[:at].to_s
  end

  # The four plain durations are always there. They wear no advice -- not "for a heavy
  # single", not "for accessories" -- because the app cannot see which this is, and inventing
  # the distinction is the guess #263 threw out.
  it 'offers plain durations with nothing claimed about them' do
    %w[1:00 2:00 3:00 5:00].each { |label| assert_includes last_response.body, label }
  end

  # The timer is markup-hidden rather than class-hidden so a browser with no JavaScript shows
  # nothing at all, which is the honest degradation: a countdown with no script is a row of
  # buttons that do nothing.
  it 'is hidden until something arms it' do
    assert_match(/id="rest-timer"[^>]*\shidden/, last_response.body)
  end
end

describe 'finishing a set' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  it 'cues the timer with the moment the set was finished' do
    tap_done(@workout_id, @set_id)

    assert_in_delta stamp_of(@set_id).to_f, cue[:at].to_f, 0.001
  end

  it 'names the movement, so the bar says what you are resting from' do
    tap_done(@workout_id, @set_id)

    assert_equal DB[:exercises].where(id: @exercise_id).get(:name), cue[:movement]
  end

  # The pair is what makes a cue new, and the poll is why. A poll swaps every panel without
  # touching the cue, so a script keying on "something was swapped" would re-offer a timer for
  # a set finished minutes ago, on every poll, forever.
  #
  # The set is carried as well as the stamp, and that is what makes the same-second case
  # work: two sets finished inside one second share a whole second -- a superset tapped off
  # in one motion -- so a cue keyed on the stamp alone would ignore the second tap and go on
  # counting the first set's rest.
  #
  # Asserted as the invariant rather than by racing two taps into one second. An earlier
  # version of this did the latter and passed locally for exactly as long as it took a slower
  # runner to straddle a second boundary. That the set differs is true either way, and it is
  # the property the timer actually relies on.
  it 'identifies a cue by the set as well as the stamp' do
    tap_done(@workout_id, @set_id)
    first = cue
    second_set = written_set(@workout_id, @exercise_id)
    tap_done(@workout_id, second_set)

    refute_empty first[:set].to_s, 'a cue with no set cannot be told from one a second later'
    refute_equal first[:set], cue[:set]
  end
end

# Three ways into the complete route and they do not all finish a set, which is the
# distinction the cue has to inherit exactly: only the taps that end a set may offer a rest.
describe 'the taps that do not finish a set' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  # Taking a mis-tap back is not the end of a set. A cue here would open a rest timer for a
  # set the lifter has just said they did not do.
  it 'cues nothing when the tap un-completes a set' do
    tap_done(@workout_id, @set_id)
    tap_done(@workout_id, @set_id)

    refute done?(@set_id)
    assert_empty cue[:at].to_s
  end

  # A rating completes a set, so it arms the timer exactly as a bare tap does -- the two are
  # the same event and the route already treats them so.
  it 'cues the timer when a rating completes the set' do
    tap_done(@workout_id, @set_id, 'rpe' => '8')

    refute_empty cue[:at].to_s
  end

  # A correction is not a completion: fixing the weight two reps into a set must not start a
  # rest timer, for the same reason it must not move the stamp (#215).
  it 'cues nothing when a correction leaves the set unfinished' do
    tap_done(@workout_id, @set_id, 'weight' => '145')

    refute done?(@set_id)
    assert_empty cue[:at].to_s
  end
end

describe 'what the timer suggests' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  # The default, and the whole point of #281's second half. A block writing five singles at
  # 90% means five minutes between them; defaulting that to whatever this lifter happened to
  # average -- including the sessions where they rushed it -- would make the timer describe
  # the habit rather than the instruction.
  it 'is the rest the programme prescribed' do
    prescribed = prescribed_set(@workout_id, @exercise_id, 300)
    tap_done(@workout_id, prescribed)

    assert_equal '300', cue[:suggested]
    assert_equal 'prescribed', cue[:kind]
  end

  # The measured median does not merely lose, it is not consulted. A lifter who rushes their
  # squats for a month must not see the timer quietly drift down to match.
  it 'prefers the prescription even where there is a history to average' do
    history(@account_id, @exercise_id, gaps: [60, 60])
    prescribed = prescribed_set(@workout_id, @exercise_id, 300)
    tap_done(@workout_id, prescribed)

    assert_equal '300', cue[:suggested]
  end
end

# There is no fallback any more, and that is the change #456 made.
#
# The timer used to offer the median of this lifter's own turnarounds where nothing was
# prescribed, labelled "your usual". It was standing in for a prescription in an app that had
# no way to write one -- and once a movement can carry its own rest, the app describing
# somebody's habit back to them is a worse answer to the same question. The habit includes the
# sessions they rushed: 632s, 9s and 343s between working bench sets average to a number
# nobody should train to.
#
# `usual_turnaround` itself is untouched. The session time estimate (#408) still reads it for
# every unlifted set, and how long a session will take is a question about the habit, which is
# what a median is actually good for.
describe 'what the timer no longer falls back to' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  it 'suggests nothing from a history of turnarounds alone' do
    history(@account_id, @exercise_id, gaps: [120, 120])
    tap_done(@workout_id, @set_id)

    assert_empty cue[:suggested].to_s
    assert_empty cue[:kind].to_s
  end

  # The bar is not empty -- the four plain durations are still there, wearing no advice. What
  # is gone is the app putting a number of its own at the front of them.
  it 'still offers the plain durations to start from' do
    history(@account_id, @exercise_id, gaps: [60, 90, 600])
    get "/workouts/#{@workout_id}/session"

    assert_includes last_response.body, 'data-rest-start="180"'
  end
end

# Which of the two numbers it is has to be said, because they are different claims. Showing a
# median under the word "prescribed" would be the app passing its own measurement off as the
# programme's instruction; the reverse would disown an instruction somebody wrote.
describe 'saying where the number came from' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
  end

  it 'offers the prescribed label to a timer counting a prescription' do
    tap_done(@workout_id, prescribed_set(@workout_id, @exercise_id, 180))

    assert_equal 'prescribed', cue[:kind]
  end

  # A rest the lifter set on the movement is prescribed too, and that is #456's whole
  # argument: what earns the bell is that somebody named the length, and this one is named on
  # a form by the person who has to rest for it.
  it 'offers the prescribed label to a rest set on the movement' do
    Tectonic::Exercise[@exercise_id].update(default_rest_seconds: 150)
    tap_done(@workout_id, written_set(@workout_id, @exercise_id))

    assert_equal 'prescribed', cue[:kind]
    assert_equal '150', cue[:suggested]
  end
end

# What it now declines to claim, which after #456 is everything it has not been told.
describe 'what the bar says nothing about' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
  end

  # A history of turnarounds no longer produces a label, because it no longer produces a
  # number.
  it 'claims nothing from a measured history' do
    history(@account_id, @exercise_id, gaps: [90, 90])
    tap_done(@workout_id, written_set(@workout_id, @exercise_id))

    assert_empty cue[:kind].to_s
  end

  it 'claims neither where it has nothing to suggest' do
    tap_done(@workout_id, written_set(@workout_id, @exercise_id))

    assert_empty cue[:kind].to_s
    assert_empty cue[:suggested].to_s
  end
end

# One word now, where there were two. The script looks the label up by the kind the cue names,
# so the label has to be on the page for it to appear -- and "your usual" went with the median
# it described.
describe 'the word the bar can say' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    account_id = login
    workout_id, = scratch_workout(account_id)
    get "/workouts/#{workout_id}/session"
  end

  it 'carries the one the script chooses' do
    assert_includes last_response.body, 'data-rest-label="prescribed"'
  end

  it 'no longer carries the one for a number the app worked out' do
    refute_includes last_response.body, 'data-rest-label="usual"'
    refute_includes last_response.body, 'your usual'
  end
end

# When it says nothing, which matters as much as the number: a suggestion invented to fill
# the gap would be the app deciding somebody's rest, and #263 settled that it does not.
describe 'what the timer will not guess at' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming
  include RestTimer

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    @set_id = written_set(@workout_id, @exercise_id)
  end

  # A movement lifted for the first time has no turnaround to take a median of, and a zero
  # would read as a suggestion of none. Absent is the honest answer, and the bar shows the
  # plain durations alone.
  it 'says nothing about a movement it has never watched' do
    tap_done(@workout_id, @set_id)

    assert_empty cue[:suggested].to_s
  end

  # The library movements are shared, so without the account scope a first squat session
  # would be offered the median turnaround of every lifter on the instance.
  it 'never reads another account for it' do
    stranger = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    history(stranger, @exercise_id, gaps: [300, 300])
    tap_done(@workout_id, @set_id)

    assert_empty cue[:suggested].to_s
  end

  # Planned sets carry no completed_at at all, but the flag is asserted as well as the stamp
  # so a future write path that stamps without completing cannot quietly feed this.
  it 'counts only sets that were actually lifted' do
    workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now - 86_400)
    3.times { written_set(workout_id, @exercise_id, is_completed: false) }
    tap_done(@workout_id, @set_id)

    assert_empty cue[:suggested].to_s
  end
end

# The word is allowed here and nowhere near the record page, which is a distinction worth
# pinning rather than leaving to whoever edits next.
#
# session_timing_spec asserts "rest" never reaches /workouts/:id, because the number there is
# a measured turnaround -- one tap per set measures the rest plus the next set's working time,
# so calling it a rest would claim a number the app cannot see. This screen is the opposite
# case: the countdown is a duration the lifter chose and started, and it is a rest exactly.
describe 'calling it a rest' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionTiming

  before do
    @account_id = login
    @workout_id, @exercise_id = scratch_workout(@account_id)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now - 120)
    written_set(@workout_id, @exercise_id, is_completed: true, completed_at: Time.now)
  end

  it 'is fine on the session screen, where the lifter chose the number' do
    get "/workouts/#{@workout_id}/session"

    assert_match(/\brest\b/i, last_response.body)
  end

  # The guard that already existed, restated here so the two screens are read together: a
  # timer on one must never put the word on the other.
  it 'is still absent from the record, where the number is measured' do
    get "/workouts/#{@workout_id}/"

    refute_match(/\brest\b/i, last_response.body)
  end
end

