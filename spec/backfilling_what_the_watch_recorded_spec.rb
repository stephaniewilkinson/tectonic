# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'matching_a_session_to_the_watch_spec' # and the forward flow's session/activity builders
require_relative '../lib/tectonic/withings_backfill'

# Importing a lifter's Withings history and offering it to the sessions they already logged.
#
# **This exercises a reversal.** #520 declines historical matching outright -- "matching an
# arbitrary past session is the hard version of this problem and this flow avoids it
# entirely" -- and the owner was asked afterwards and chose to have it anyway, as a second
# piece standing on the forward flow. So what is asserted here is the hard version behaving:
# that it proposes and never decides, that running it twice is running it once, and that a
# walk which did not finish cannot report itself as one that did.
#
# **Nothing here calls Withings**, exactly as the forward flow's specs do not. Every fetch is
# stubbed. A suite that reached the network would be a suite that fails on a train, and a
# backfill spec that reached it would be a hundred requests per run.
module Backfilling
  include MatchingTheWatch

  # Far enough back that the forward flow has long stopped asking about it -- LOOKS_BACK is a
  # day -- and recent enough that the walk is two or three years rather than a decade.
  MONTHS_AGO = 300 * 24 * 60 * 60

  def long_ago = Time.now - MONTHS_AGO

  # Withings answering with whatever activities fall inside the year being asked about, which
  # is what a year-chunked walk actually sees. Returning every activity for every year would
  # make the found count a multiple of the truth and hide a walk that asked for the same year
  # twice.
  def answering(*activities)
    lambda do |_token, from:, **_rest|
      activities.select { |found| Time.at(found['startdate']).year == from.year }
    end
  end

  def backfill(account_id, answer, **)
    Tectonic::Withings.stub(:workouts, answer) do
      Tectonic::WithingsBackfill.run(account_id:, pause: 0, **)
    end
  end

  # The forms that actually went over the wire, for the assertions about how the history is
  # walked rather than about what comes out of it.
  def asked_for(account_id, **)
    asked = []
    recording = lambda do |_path, **form|
      asked << [form[:startdateymd], form[:enddateymd]]
      { 'series' => [] }
    end
    Tectonic::Withings.stub(:post, recording) do
      Tectonic::WithingsBackfill.run(account_id:, pause: 0, **)
    end
    asked
  end

  def years_from(year) = (year..Date.today.year).to_a.reverse.map { |y| ["#{y}-01-01", "#{y}-12-31"] }

  # A history already walked once: one session months old, one activity that fits it, and
  # therefore one proposal waiting. The state most of the claims below are about.
  def already_backfilled
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
    @found = activity(starts: @at + 60, minutes: 48)
    backfill(@account_id, answering(@found))
  end

  # And the same walk again, over the same years, which is the thing that has to be a no-op.
  def again = backfill(@account_id, answering(@found), since: @at.year)

  def connection(account_id) = DB[:account_withings].where(account_id:).first

  def proposals(account_id) = DB[:withings_workouts].where(account_id:).exclude(proposed_workout_id: nil).all
end

describe 'the range a backfill asks Withings for' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
  end

  # No maximum window width is documented for getworkouts, and an undocumented limit is not
  # an absent one -- it reports itself by returning fewer rows, and a truncated answer from
  # this endpoint is indistinguishable from a quiet year.
  it 'is a year at a time rather than one unbounded span' do
    assert_equal years_from(@at.year), asked_for(@account_id)
  end

  # So that a walk cut short by a throttle has already done the years whose sessions a
  # lifter can still remember well enough to confirm.
  it 'starts at this year and works backwards' do
    assert_equal ["#{Date.today.year}-01-01", "#{Date.today.year}-12-31"], asked_for(@account_id).first
  end

  # The floor comes out of Tectonic's own data: a year before the first logged session holds
  # nothing that could ever be proposed to anything.
  it 'stops at the year of the earliest stamped set this lifter has' do
    assert_equal ["#{@at.year}-01-01", "#{@at.year}-12-31"], asked_for(@account_id).last
  end

  # An operator naming a year is making a claim this module cannot check, so it is obeyed
  # rather than folded into the floor above.
  it 'takes a bound from the operator instead when it is given one' do
    assert_equal years_from(@at.year - 3), asked_for(@account_id, since: @at.year - 3)
  end
end

describe 'the pace a walk keeps' do
  include Backfilling

  # Withings ask for no more than one poll every ten minutes per user, and the commonly cited
  # application ceiling is 120 requests a minute. A serial walk with a second between pages is
  # far under both; the same walk with no pause is a tight loop against somebody else's
  # service, and the way that ends is status 601 -- which arrives as HTTP 200 and cannot be
  # told apart from an afternoon with nothing in it.
  it 'asks for a pause between pages rather than going as fast as it can' do
    given = nil
    Tectonic::Withings.stub(:workouts, ->(_token, pause: nil, **) { (given = pause) && [] }) do
      Tectonic::WithingsBackfill.fetch_year('access-1', 2025, Tectonic::WithingsBackfill::PAUSE)
    end

    assert_operator given, :>, 0
  end
end

describe 'a walk Withings stopped answering part way' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id, started_at: long_ago)
    @report = backfill(@account_id, nil)
  end

  # The trap this whole integration keeps walking into. Withings signal rate limiting as body
  # status 601 over HTTP 200, and `Withings.answered` folds that into the same nil as a
  # revoked token -- so a throttled walk arrives here looking exactly like a finished one
  # that found nothing at all.
  it 'says so rather than reporting a history with nothing in it' do
    refute @report[:complete]
    assert_equal Date.today.year, @report[:stopped_at]
  end

  # The watermark means "everything older than this has been read". A walk that was throttled
  # in its first year cannot say that, and stamping it would mean the years it never reached
  # are never read again.
  it 'leaves the backfill watermark unstamped' do
    assert_nil connection(@account_id)[:workouts_backfilled_at]
  end
end

describe 'a walk that finished' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
    backfill(@account_id, answering(activity(starts: @at)))
  end

  it 'stamps a watermark of its own' do
    refute_nil connection(@account_id)[:workouts_backfilled_at]
  end

  # `synced_at` is the measurement poll's resume cursor. Stamping it from a workout fetch
  # would tell that poll it had already read a window of bodyweights nobody has fetched, and
  # those readings would simply never arrive.
  it 'never touches the resume cursor the measurement poll uses' do
    assert_nil connection(@account_id)[:synced_at]
  end

  # Everything older than a completed walk is already stored, so re-reading a decade to write
  # the same rows again is a hundred requests for nothing.
  it 'starts the next run at the year it got to' do
    assert_equal years_from(Date.today.year), asked_for(@account_id)
  end
end

describe 'what a backfill does with an activity that fits a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
    @report = backfill(@account_id, answering(activity(starts: @at + 60, minutes: 48)))
  end

  # The line #520 draws and this reversal does not cross: the backfill finds and offers, and
  # the lifter decides. A version that wrote `workout_id` would be the silent matching the
  # issue refuses most loudly, applied to a year of training at once.
  it 'offers it and does not claim it' do
    assert_equal @workout_id, proposals(@account_id).first[:proposed_workout_id]
    assert_nil proposals(@account_id).first[:workout_id]
  end

  it 'counts the proposal it made' do
    assert_equal 1, @report[:proposed]
    assert_equal 1, @report[:found]
  end
end

describe 'what a backfill does with the two kinds of nothing' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
  end

  # A walk, a bike ride, or a session trained and never logged here. Counted rather than
  # swallowed, because it is the number that says whether the matching worked or merely ran.
  it 'counts a watch activity no session can claim' do
    report = backfill(@account_id, answering(activity(starts: @at - (6 * 3600), minutes: 40)))

    assert_equal 1, report[:activities_without_session]
    assert_equal 0, report[:proposed]
  end

  # And says it plainly. For a session from last March there is no upload on its way, so the
  # forward flow's "check back in a minute" would be a promise nothing is going to keep.
  it 'counts a session the watch recorded nothing for' do
    report = backfill(@account_id, answering)

    assert_equal 1, report[:without_activity]
  end

  # #520 requires a no to stick per session and permanently. A backfill re-proposing to a
  # session the lifter waved away would be that nagging arriving months later and in bulk.
  it 'leaves a session the lifter has already dismissed alone' do
    Tectonic::WithingsWorkouts.dismiss(account_id: @account_id, workout_id: @workout_id)
    report = backfill(@account_id, answering(activity(starts: @at + 60, minutes: 48)))

    assert_equal 0, report[:proposed]
    assert_empty proposals(@account_id)
  end
end

describe 'running a backfill twice' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before { already_backfilled }

  # Idempotency is the whole of whether this is safe to run at all. A second run that made a
  # second proposal would double a lifter's queue every time somebody was unsure whether the
  # first one had worked.
  it 'proposes nothing the second time' do
    report = again

    assert_equal 0, report[:proposed]
    assert_equal 1, report[:already_waiting]
    assert_equal 1, proposals(@account_id).length
  end

  it 'stores one row however many times the history is walked' do
    again

    assert_equal 1, DB[:withings_workouts].where(account_id: @account_id).count
  end
end

describe 'a re-run and an answer the lifter has already given' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before { already_backfilled }

  # The lifter's answer is not Withings' to overwrite, and Withings keep sending an activity
  # that has been answered because it is still sitting in their account. This inherits the
  # guarantee from `WithingsWorkouts.store` rather than restating it.
  it 'does not un-answer a confirmed match' do
    Tectonic::WithingsWorkouts.confirm(account_id: @account_id, workout_id: @workout_id, external_id: 'w-1')
    again

    assert_equal @workout_id, DB[:withings_workouts].where(external_id: 'w-1').get(:workout_id)
  end

  it 'does not un-refuse a dismissed activity' do
    Tectonic::WithingsWorkouts.dismiss(account_id: @account_id, workout_id: @workout_id, external_id: 'w-1')
    again

    refute_nil DB[:withings_workouts].where(external_id: 'w-1').get(:dismissed_at)
  end
end

describe 'one activity two sessions could both claim' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @first = trained_session(@account_id, started_at: @at, minutes: 52)
    @found = activity(starts: @at + 60, minutes: 48)
  end

  # `workout_id` is unique, so two sessions both claiming one recording would end with the
  # second yes silently doing nothing. One offer, and the other session is told plainly that
  # the watch has nothing for it.
  it 'is offered to one of them and not to both' do
    trained_session(@account_id, started_at: @at + 600, minutes: 40)
    report = backfill(@account_id, answering(@found))

    assert_equal 1, report[:proposed]
    assert_equal 1, report[:without_activity]
  end

  # And the offer survives a session logged later that would also have fitted: the activity
  # is spoken for, and re-offering it would put the same recording in two places on the
  # review list.
  it 'stays with the session it was offered to when a later run sees another' do
    backfill(@account_id, answering(@found))
    trained_session(@account_id, started_at: @at + 600, minutes: 40)
    report = again

    assert_equal 0, report[:proposed]
    assert_equal 1, proposals(@account_id).length
    assert_equal @first, proposals(@account_id).first[:proposed_workout_id]
  end
end

describe 'a dry run' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before do
    @account_id = login
    connect(@account_id)
    @at = long_ago
    @workout_id = trained_session(@account_id, started_at: @at)
    @report = backfill(@account_id, answering(activity(starts: @at + 60, minutes: 48)), dry_run: true)
  end

  it 'writes nothing at all' do
    assert_empty DB[:withings_workouts].all
    assert_nil connection(@account_id)[:workouts_backfilled_at]
  end

  # It is the real walk inside a transaction that always rolls back, rather than a second
  # code path that estimates the first. An estimate written separately drifts, and the drift
  # shows up as a preview that says eleven and a run that writes nine.
  it 'reports the numbers a real run would produce' do
    assert_equal 1, @report[:proposed]
    assert @report[:dry_run]
  end
end

describe 'an account with nothing to match against' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  it 'is refused before a single request is made' do
    account_id = login
    connect(account_id)
    asked = []
    Tectonic::Withings.stub(:post, ->(_path, **_form) { asked << 1 }) do
      assert_equal({ state: :no_sessions }, Tectonic::WithingsBackfill.run(account_id:, pause: 0))
    end

    assert_empty asked
  end

  it 'says so rather than walking a decade for an account with no connection' do
    assert_equal({ state: :disconnected }, Tectonic::WithingsBackfill.run(account_id: login, pause: 0))
  end
end

describe 'the record of a session a backfill proposed a match for' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before { already_backfilled }

  # The seam #528 named: LOOKS_BACK is 24 hours and this session is months old. What is
  # widened is which sessions may show a question, not how long the app keeps asking.
  it 'asks the question even though the session is months old' do
    get "/workouts/#{@workout_id}"

    assert_includes last_response.body, 'Was that this session?'
    assert_includes last_response.body, 'overlaps this session for'
  end

  # Which is the constraint that makes widening it safe. Browsing a year of training must not
  # become a year of API calls -- that is how a read-only integration gets itself throttled,
  # and a throttle is the one failure this page cannot render honestly.
  it 'asks Withings nothing to do it' do
    actions = []
    Tectonic::Withings.stub(:post, ->(_path, **form) { actions << form[:action] }) { get "/workouts/#{@workout_id}" }

    assert_empty actions
  end

  it 'is answered through the same route the forward flow uses' do
    token = token_for_form("/workouts/#{@workout_id}", "/workouts/#{@workout_id}/withings/match")
    post "/workouts/#{@workout_id}/withings/match", { '_csrf' => token, 'activity' => 'w-1' }

    assert_equal @workout_id, DB[:withings_workouts].where(external_id: 'w-1').get(:workout_id)
  end
end

describe 'the record of an old session with no proposal waiting' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  # Absent is absent. The forward flow's "nothing from Withings yet" is true about an upload
  # that is seconds behind and a lie about a session from last March, so an old session with
  # nothing waiting says nothing whatever and the run that found the absence is where it gets
  # counted out loud.
  it 'says nothing rather than borrowing the hedge the forward flow uses' do
    account_id = login
    connect(account_id)
    workout_id = trained_session(account_id, started_at: long_ago)
    get "/workouts/#{workout_id}"

    refute_includes last_response.body, 'Nothing from Withings yet'
    refute_includes last_response.body, 'Was that this session?'
  end
end

describe 'the list of proposals waiting for an answer' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before { already_backfilled }

  # Answering eighty proposals by finding eighty days in a list ordered by date -- a list
  # that says nothing about which days carry a question -- is a feature nobody finishes.
  it 'names the session each proposal is about' do
    get '/workouts/withings'

    assert_includes last_response.body, @at.strftime('%b %d, %Y')
    assert_includes last_response.body, 'Was that this session?'
  end

  it 'shows the evidence rather than only the guess' do
    get '/workouts/withings'

    assert_includes last_response.body, 'overlaps this session for'
  end

  it 'empties as they are answered, without promising more are coming' do
    Tectonic::WithingsWorkouts.confirm(account_id: @account_id, workout_id: @workout_id, external_id: 'w-1')
    get '/workouts/withings'

    assert_includes last_response.body, 'Nothing is waiting'
    refute_includes last_response.body, 'check back'
  end
end

describe 'answering a proposal from the list rather than from a record' do
  include Rack::Test::Methods
  include RouteOwnership
  include Backfilling

  before { already_backfilled }

  # Sending somebody to a record page after each answer would make a hundred answers into a
  # hundred trips back.
  it 'comes back to the list when an answer is given from it' do
    token = token_for_form('/workouts/withings', "/workouts/#{@workout_id}/withings/match")
    post "/workouts/#{@workout_id}/withings/match", { '_csrf' => token, 'activity' => 'w-1', 'back' => 'proposals' }

    assert_equal '/workouts/withings', last_response.headers['Location']
  end

  # A redirect that echoed a form value would be an open redirect: a planted form could
  # bounce a signed-in lifter off the app entirely.
  it 'will not be sent anywhere a form asks for' do
    token = token_for_form('/workouts/withings', "/workouts/#{@workout_id}/withings/dismiss")
    post "/workouts/#{@workout_id}/withings/dismiss",
         { '_csrf' => token, 'activity' => 'w-1', 'back' => 'https://elsewhere.example' }

    assert_equal "/workouts/#{@workout_id}", last_response.headers['Location']
  end
end

