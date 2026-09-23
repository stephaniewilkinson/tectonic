# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/withings_workouts'

# Asking whether a session was the thing the watch recorded. #520.
#
# **Nothing here calls Withings.** Every fetch is stubbed, the same way
# connecting_a_scale_spec stubs the token exchange: you cannot meaningfully test somebody
# else's API, only this app's handling of what it sends back -- and a suite that reached the
# network would be a suite that fails when a laptop is on a train.
#
# What is asserted is the part that is ours: which interval a session has, which activity
# overlaps it, which of four things the page says, and what a yes and a no leave behind.
#
# The describes are small and many rather than few and long, which is the shape the linter
# enforces and also the one that reads: each names one claim about the flow.
module MatchingTheWatch
  # A session with two completed sets, an hour ago, finished. An hour ago rather than last
  # week because the proposal is a forward flow and deliberately stops looking after
  # LOOKS_BACK -- there is a describe below that asserts that boundary on purpose.
  def trained_session(account_id, started_at: Time.now - 3600, minutes: 52)
    ended_at = started_at + (minutes * 60)
    workout_id = DB[:workouts].insert(account_id:, date: started_at.to_date.to_time,
                                      finished_at: ended_at)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    [started_at, ended_at].each do |at|
      DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5,
                       is_warmup: false, is_completed: true, completed_at: at)
    end
    workout_id
  end

  # What `getworkouts` answers with, once `data_fields` has been asked for. Epoch integers
  # for the two ends, which is Withings' shape and the reason the columns are instants.
  def activity(id: 'w-1', starts: Time.now - 3600, minutes: 50, category: 16, **extra)
    { 'id' => id, 'category' => category, 'timezone' => 'America/New_York',
      'attrib' => 0, 'startdate' => starts.to_i, 'enddate' => (starts + (minutes * 60)).to_i,
      'modified' => starts.to_i,
      'data' => { 'calories' => 310.5, 'effduration' => 2400, 'hr_average' => 128,
                  'hr_min' => 61, 'hr_max' => 164 } }.merge(extra)
  end

  # A live connection, so `proposal` gets past the gate that keeps an unconnected account's
  # record page from mentioning Withings at all.
  def connect(account_id)
    Tectonic::WithingsConnection.store(account_id,
                                       { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
                                         'expires_in' => 10_800, 'userid' => '9001' })
  end

  # The page, with whatever Withings was going to answer stubbed out. `nil` is the answer
  # that means "Withings did not say" -- a throttle, a revoked grant, a timeout -- and `[]`
  # is the one that means "Withings said there was nothing".
  def record(workout_id, answer)
    Tectonic::Withings.stub(:workouts, answer) { get "/workouts/#{workout_id}" }
  end

  def stored(account_id) = DB[:withings_workouts].where(account_id:).all

  # A 52 minute session to score candidates against, fixed on first use. `Time.now` read
  # twice is two different instants, and a window that moved between building an activity
  # and scoring it would put every arithmetic assertion here out by however long the test
  # took. Minitest builds one instance per test, so the memo cannot leak between them.
  def window
    @window ||= [Time.now - 3600, Time.now - 3600 + (52 * 60)]
  end

  def row(starts_offset:, minutes:, category: 16, id: 'w')
    opened = window.first + (starts_offset * 60)
    { external_id: id, started_at: opened, ended_at: opened + (minutes * 60), category: }
  end

  def best(*rows) = Tectonic::WithingsWorkouts.best(rows, window)[:external_id]
end

describe 'the interval a session is matched on' do
  include MatchingTheWatch

  # workouts.date only ever holds midnight -- every writer puts a date in it -- so a matcher
  # that used it would compare every session in the database against the small hours of its
  # own morning and match nothing, or worse, match whatever the lifter did at 00:30.
  it 'comes from the set stamps rather than from the date column, which is always midnight' do
    timing = { started_at: window.first, ended_at: window.last }

    assert_equal window, Tectonic::WithingsWorkouts.interval(timing)
  end

  it 'is nothing at all for a session with no completed sets' do
    assert_nil Tectonic::WithingsWorkouts.interval({ started_at: nil, ended_at: nil })
  end

  # A session of zero width overlaps nothing, and scoring one would divide by zero.
  it 'is nothing for a session whose two ends are the same instant' do
    at = Time.now

    assert_nil Tectonic::WithingsWorkouts.interval({ started_at: at, ended_at: at })
  end
end

describe 'which activity gets proposed' do
  include MatchingTheWatch

  it 'prefers the one that covers more of the session' do
    barely = row(starts_offset: 45, minutes: 10, id: 'barely')
    mostly = row(starts_offset: 1, minutes: 50, id: 'mostly')

    assert_equal 'mostly', best(barely, mostly)
  end

  # Category is evidence and never a filter: a lifter who tapped "Other" still lifted.
  it 'prefers a lifting category where the overlap is otherwise equal' do
    other = row(starts_offset: 0, minutes: 52, category: 1, id: 'other')
    lifted = row(starts_offset: 0, minutes: 52, category: 16, id: 'lifted')

    assert_equal 'lifted', best(other, lifted)
  end

  # And the bonus is not big enough to overturn a measurement. A walk tagged "Lift weights"
  # that touched a tenth of the session must lose to an untagged recording of all of it.
  it 'does not let the category outweigh an overlap that is plainly better' do
    tagged = row(starts_offset: 46, minutes: 6, category: 16, id: 'tagged')
    untagged = row(starts_offset: 0, minutes: 52, category: 1, id: 'untagged')

    assert_equal 'untagged', best(tagged, untagged)
  end
end

describe 'two recordings of the same session' do
  include MatchingTheWatch

  # A watch and a phone both listening tie on overlap, and the one started for the session
  # is the one that began nearest the first set.
  it 'is settled by whichever started nearest the first set' do
    late = row(starts_offset: 10, minutes: 42, category: 16, id: 'late')
    prompt = row(starts_offset: 0, minutes: 42, category: 16, id: 'prompt')

    assert_equal 'prompt', best(late, prompt)
  end

  # A score between nought and one and a quarter is not something a lifter can agree with.
  # "These overlap for 48 of 52 minutes" is, and it is the same fact.
  it 'is explained in a sentence a lifter can disagree with' do
    covering = row(starts_offset: 2, minutes: 48, category: 16)

    assert_equal 'overlaps this session for 48m of its 52m, and Withings called it lift weights',
                 Tectonic::WithingsWorkouts.because(covering, window)
  end
end

describe 'the overlap gate' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @started_at = Time.now - 3600
    @workout_id = trained_session(@account_id, started_at: @started_at)
  end

  it 'proposes an activity that overlaps the session' do
    record(@workout_id, [activity(starts: @started_at)])

    assert_includes last_response.body, 'Was that this session?'
  end

  # An activity that finished before the first set began is a different thing that happened
  # that day, and offering it would be the silent matching #520 refuses in a louder voice.
  it 'does not propose one that ended before the session started' do
    record(@workout_id, [activity(starts: @started_at - 7200, minutes: 60)])

    assert_includes last_response.body, 'Nothing from Withings yet'
  end

  # Touching at an instant is not overlapping. The gate is strict on both sides.
  it 'does not propose one that merely ends where the session begins' do
    record(@workout_id, [activity(starts: @started_at - 3600, minutes: 60)])

    refute_includes last_response.body, 'Was that this session?'
  end

  # A session logged hours after it was lifted carries the logging time, and nothing
  # overlaps it. That is a correct "no match" rather than something to paper over.
  it 'finds nothing for a session logged long after it was trained' do
    record(@workout_id, [activity(starts: Time.now - (9 * 3600), minutes: 50)])

    assert_includes last_response.body, 'Nothing from Withings yet'
  end
end

describe 'a fetch that came back empty' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id)
  end

  # **Late is not absent.** Closing a workout in Withings starts an upload that lands
  # seconds to minutes later, so a lifter who taps finish and reads this at once is the
  # ordinary case. "No activity found" would be a lie about a thing that is on its way --
  # the same distinction 041 draws by storing `measured_at` apart from when a row appeared.
  it 'says to check back rather than that there was no activity' do
    record(@workout_id, [])

    assert_includes last_response.body, 'Nothing from Withings yet'
    refute_includes last_response.body, 'No activity'
  end

  # A lifter who simply did not wear the watch has nothing to confirm, and would otherwise
  # be told to check back in a minute every time they opened the page.
  it 'can still be dismissed, because there is nothing coming for this session' do
    record(@workout_id, [])

    assert_includes last_response.body, 'withings/dismiss'
  end
end

describe 'a fetch that did not come back at all' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id)
  end

  # The trap. Withings signals rate limiting as body status 601 and delivers it over HTTP
  # 200, and `Withings.answered` folds that into the same nil as a revoked token -- so a
  # throttled fetch arrives here looking exactly like an empty one. Rendering it as "nothing
  # yet" would be the app asserting something about an afternoon it never asked about.
  it 'says Withings could not be reached rather than that nothing arrived' do
    record(@workout_id, nil)

    assert_includes last_response.body, 'could not be reached'
    refute_includes last_response.body, 'Nothing from Withings yet'
  end

  # Dismissing answers a question, and this state is the app admitting it has not managed to
  # ask one.
  it 'offers no way to dismiss a question it never managed to ask' do
    record(@workout_id, nil)

    refute_includes last_response.body, 'withings/dismiss'
  end
end

describe 'a record page with nothing to ask about' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before { @account_id = login }

  # An account that has never connected has no business being told about Withings at all.
  it 'says nothing whatever on an account with no connection' do
    record(trained_session(@account_id), [activity])

    refute_includes last_response.body, 'Withings'
  end

  # The proposal is a forward flow. #520 declines to match arbitrary past sessions, and
  # re-asking on every view of a year of training is how a read-only integration gets itself
  # rate-limited -- which is the one failure this page cannot render honestly.
  it 'stops looking once a session is a day old' do
    connect(@account_id)
    old = trained_session(@account_id, started_at: Time.now - (30 * 3600))
    record(old, [activity(starts: Time.now - (30 * 3600))])

    refute_includes last_response.body, 'Nothing from Withings yet'
    refute_includes last_response.body, 'Was that this session?'
  end
end

# Saying yes. Split across three describes because the linter counts lines and because each
# of them is a separate claim about what confirming does.
module SayingYes
  include MatchingTheWatch

  def answer(action, **params)
    offered = [activity(starts: @started_at + 60, minutes: 48)]
    token = Tectonic::Withings.stub(:workouts, offered) do
      token_for_form("/workouts/#{@workout_id}", "/workouts/#{@workout_id}/withings/#{action}")
    end
    post "/workouts/#{@workout_id}/withings/#{action}", { '_csrf' => token, **params }
  end

  def a_session_with_an_offer
    @account_id = login
    connect(@account_id)
    @started_at = Time.now - 3600
    @workout_id = trained_session(@account_id, started_at: @started_at)
    record(@workout_id, [activity(starts: @started_at + 60, minutes: 48)])
  end
end

describe 'confirming a match' do
  include Rack::Test::Methods
  include RouteOwnership
  include SayingYes

  before { a_session_with_an_offer }

  it 'links the activity to the session' do
    answer('match', 'activity' => 'w-1')

    assert_equal @workout_id, DB[:withings_workouts].where(external_id: 'w-1').get(:workout_id)
  end

  # A match made is a fact about the session forever, so the question does not come back --
  # not even when a second overlapping activity turns up on the next fetch.
  it 'stops asking' do
    answer('match', 'activity' => 'w-1')
    record(@workout_id, [activity(id: 'w-2', starts: @started_at + 60, minutes: 48)])

    refute_includes last_response.body, 'Was that this session?'
  end

  # A second confirmation arriving from a page left open must not move a match already made:
  # the unique index on workout_id would make it an exception rather than a no-op.
  it 'refuses a second activity for a session already matched' do
    answer('match', 'activity' => 'w-1')
    again = Tectonic::WithingsWorkouts.confirm(account_id: @account_id, workout_id: @workout_id,
                                               external_id: 'w-9')

    assert_equal 0, again
  end
end

describe 'the record page once a match is confirmed' do
  include Rack::Test::Methods
  include RouteOwnership
  include SayingYes

  before do
    a_session_with_an_offer
    answer('match', 'activity' => 'w-1')
    record(@workout_id, [])
  end

  # Where the two disagree about how long a session took, the watch is right -- and the page
  # has to say that it is deferring, or a number silently changes meaning depending on
  # whether a match exists.
  it 'prefers the length the watch measured, and says whose it is' do
    assert_includes last_response.body, '48m measured by your watch'
    assert_includes last_response.body, 'from your taps'
  end

  it 'prefers the two ends the watch measured too' do
    assert_includes last_response.body, 'on your watch'
  end

  it 'shows the heart rate, which only the watch has' do
    assert_includes last_response.body, '128 bpm average'
  end
end

describe 'saying no' do
  include Rack::Test::Methods
  include RouteOwnership
  include SayingYes

  before { a_session_with_an_offer }

  # #520: "dismissing the prompt has to stick -- per workout, permanently."
  it 'never asks about that session again' do
    answer('dismiss', 'activity' => 'w-1')
    record(@workout_id, [activity(id: 'w-2', starts: @started_at + 60, minutes: 48)])

    refute_includes last_response.body, 'Was that this session?'
    refute_includes last_response.body, 'Nothing from Withings yet'
  end

  # The row is kept rather than deleted, because Withings will hand the same activity back
  # on the next fetch and a deleted one would simply return and be proposed afresh.
  it 'keeps the activity and marks it refused rather than deleting it' do
    answer('dismiss', 'activity' => 'w-1')
    refused = DB[:withings_workouts].where(external_id: 'w-1').first

    refute_nil refused[:dismissed_at]
  end

  # And it is sayable with no activity id at all, which is the case a lifter who does not
  # wear the watch on Thursdays is in.
  it 'can be said about a session Withings has nothing for' do
    answer('dismiss')
    record(@workout_id, [])

    refute_includes last_response.body, 'Nothing from Withings yet'
  end
end

describe 'storing what Withings sent' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id)
  end

  # Re-reading a window that overlaps one already stored is deliberate, and the unique index
  # is what makes the second read a no-op rather than a second copy of the afternoon.
  it 'writes one row however many times the page is opened' do
    3.times { record(@workout_id, [activity]) }

    assert_equal 1, stored(@account_id).length
  end

  # The fields `getworkouts` will not send unless `data_fields` asks for them by name. A
  # caller that did not ask gets ids, category and timestamps, and no error at all.
  it 'keeps the measurements that had to be asked for' do
    record(@workout_id, [activity])

    assert_equal 128, stored(@account_id).first[:hr_average]
    assert_equal 2400, stored(@account_id).first[:effective_seconds]
  end

  # A watch with no optical sensor records no heart rate. Nil and zero are different facts.
  it 'leaves a measurement the watch did not take as nothing rather than zero' do
    record(@workout_id, [activity.merge('data' => {})])

    assert_nil stored(@account_id).first[:hr_average]
  end
end

describe 'the epochs Withings sends' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  # Turned into instants on the way in, so that no reader has to remember to convert and
  # none of them can forget.
  it 'are stored as instants' do
    account_id = login
    connect(account_id)
    starts = Time.now - 3600
    record(trained_session(account_id), [activity(starts:)])

    assert_in_delta starts, stored(account_id).first[:started_at], 1
  end
end

describe 'a second fetch of the same activity' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id)
    record(@workout_id, [activity])
  end

  # The lifter's answer is not Withings' to overwrite, and Withings keeps sending an activity
  # that has been answered because it is still sitting in their account.
  it 'does not un-answer a confirmed match' do
    DB[:withings_workouts].where(external_id: 'w-1').update(workout_id: @workout_id)
    record(@workout_id, [activity])

    assert_equal @workout_id, DB[:withings_workouts].where(external_id: 'w-1').get(:workout_id)
  end

  it 'does not un-refuse a dismissed activity' do
    DB[:withings_workouts].where(external_id: 'w-1').update(dismissed_at: Time.now)
    record(@workout_id, [activity])

    refute_nil DB[:withings_workouts].where(external_id: 'w-1').get(:dismissed_at)
  end

  # It does keep up with a revision, which is the other half of an upsert being worth having.
  it 'takes a revised interval' do
    record(@workout_id, [activity(minutes: 55)])
    row = stored(@account_id).first

    assert_in_delta 55 * 60, row[:ended_at] - row[:started_at], 1
  end
end

# What goes over the wire, which is the half of this that cannot be read off the page.
module AskingWithings
  include MatchingTheWatch

  # Recorded rather than asserted inside the lambda, so a lambda that is never called fails
  # on a nil instead of passing by never reaching its assertion.
  def recording_form(&)
    asked = nil
    answering = lambda do |_path, **form|
      asked = form
      { 'series' => [] }
    end
    Tectonic::Withings.stub(:post, answering, &)
    asked
  end
end

describe 'the request the app makes for activities' do
  include Rack::Test::Methods
  include RouteOwnership
  include AskingWithings

  # The fields, by name, because nothing but ids, category and timestamps comes back without
  # them -- and it comes back without them silently.
  it 'asks for the data fields by name' do
    asked = recording_form do
      Tectonic::Withings.workouts('access-1', from: Date.today, to: Date.today)
    end

    assert_equal 'getworkouts', asked[:action]
    assert_equal 'calories,effduration,hr_average,hr_min,hr_max', asked[:data_fields]
  end

  # Civil dates rather than the epochs the rest of the module deals in, and no `lastupdate`
  # beside them: the published spec marks all three required and they are in fact mutually
  # exclusive.
  it 'sends the civil date pair and not a lastupdate cursor' do
    asked = recording_form do
      Tectonic::Withings.workouts('access-1', from: Date.new(2026, 9, 22), to: Date.new(2026, 9, 24))
    end

    assert_equal '2026-09-22', asked[:startdateymd]
    assert_equal '2026-09-24', asked[:enddateymd]
    refute asked.key?(:lastupdate)
  end
end

describe 'an answer that arrives in pages' do
  include Rack::Test::Methods
  include RouteOwnership
  include AskingWithings

  # Withings answers a wide window with `more` and an `offset` to send back, and a caller
  # that read the first page and stopped would lose the rest silently -- at exactly the
  # moment a lifter had had a busy fortnight.
  it 'follows the pages until Withings says there are no more' do
    pages = [{ 'series' => [{ 'id' => 1 }], 'more' => true, 'offset' => 1 },
             { 'series' => [{ 'id' => 2 }], 'more' => false }]
    asked = []
    answering = lambda do |_path, **form|
      asked << form[:offset]
      pages.shift
    end
    found = Tectonic::Withings.stub(:post, answering) do
      Tectonic::Withings.workouts('access-1', from: Date.today, to: Date.today)
    end

    assert_equal [0, 1], asked
    assert_equal [1, 2], found.map { |page| page['id'] }.sort
  end

  # A page that failed is not a short answer. Returning what had been gathered would make a
  # throttle look like a result.
  it 'answers nothing at all when a page fails rather than a short list' do
    pages = [{ 'series' => [{ 'id' => 1 }], 'more' => true, 'offset' => 1 }, nil]
    Tectonic::Withings.stub(:post, ->(_path, **_form) { pages.shift }) do
      assert_nil Tectonic::Withings.workouts('access-1', from: Date.today, to: Date.today)
    end
  end
end

describe 'what the app is allowed to ask Withings to do' do
  include Rack::Test::Methods
  include RouteOwnership
  include AskingWithings

  before do
    @account_id = login
    connect(@account_id)
  end

  # The app reads; the watch is the instrument. #520. Asserted over a real page view rather
  # than over the module, because the route is where a write would be added by accident.
  it 'never asks Withings to write anything' do
    workout_id = trained_session(@account_id)
    actions = []
    answering = lambda do |_path, **form|
      actions << form[:action]
      { 'series' => [] }
    end
    Tectonic::Withings.stub(:post, answering) { get "/workouts/#{workout_id}" }

    assert_equal %w[getworkouts], actions.uniq
  end
end

