# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # account/login/CSRF helpers; idempotent require
require_relative 'backfilling_what_the_watch_recorded_spec' # and the walk's own builders
require_relative '../lib/tectonic/withings_backfill'

# Importing your own history from the settings page, one year per press. #558.
#
# The matching shipped in two halves and only one of them was reachable. A session finished
# today gets its proposal on its own record, with no terminal and nothing to run; every
# session logged before today could only get one from `rake withings:backfill`, which means a
# shell with the production database in reach. So the lifter this was built for could not
# import their own history at all, and the screen that lists proposals was a screen nothing
# could put anything on.
#
# What is asserted here is a press that is *bounded and honest*: it reads one year, it says
# which year it read and whether there is another, and a year Withings refused to answer is
# never reported as a year with nothing in it. That last one is the whole of the feature --
# status 601 arrives inside an HTTP 200, `Withings.workouts` folds it into the same nil as a
# revoked token, and a press rendered as a tidy zero would retire a year of training nobody
# ever looked at.
#
# **Nothing here calls Withings.** Every fetch is stubbed, exactly as the backfill's and the
# forward flow's specs are.
module ImportingHistory
  include Backfilling

  # A session in a named year rather than "a while ago", because the assertions below count
  # presses -- one per year from this one back to the earliest stamped set -- and a relative
  # stamp would make that count depend on the day the suite runs.
  def session_in(year, account_id)
    trained_session(account_id, started_at: Time.new(year, 6, 15, 10, 0, 0), minutes: 52)
  end

  def this_year = Date.today.year

  # A connected account whose earliest session is two years back, so there are three presses
  # in it: this year, last year, the year before.
  def lifter_with_history
    @account_id = login
    connect(@account_id)
    @at = Time.new(this_year - 2, 6, 15, 10, 0, 0)
    @workout_id = session_in(this_year - 2, @account_id)
    @found = activity(starts: @at + 60, minutes: 48)
  end

  # The press itself, with whatever Withings was going to answer stubbed out. `nil` is the
  # answer that means "Withings did not say"; `[]` is the one that means it said nothing.
  def press(answer = answering)
    token = token_for_form('/settings', '/settings/withings/import')
    Tectonic::Withings.stub(:workouts, answer) { post '/settings/withings/import', { '_csrf' => token } }
    follow_redirect!
  end

  # A press that writes down which year it was asked for, answering with this lifter's one
  # activity only for the year that actually holds it -- which is what a year-chunked walk
  # sees, and what makes "it read one year" assertable rather than assumed.
  def press_recording(asked)
    press(lambda do |_token, from:, **_rest|
      asked << from.year
      from.year == @at.year ? [@found] : []
    end)
  end

  def imported_year(account_id) = DB[:account_withings].where(account_id:).get(:workouts_imported_year)
end

describe 'the settings page before anybody has imported anything' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_history
    get '/settings'
  end

  # A control that silently spends a minute talking to somebody else's server is
  # indistinguishable, on a phone, from one that has crashed -- and the lifter who presses it
  # again has made two years of requests to the provider whose rate limit this app cannot see
  # coming. So the year is on the button, and the sentence says what a press costs.
  it 'says which year a press would read, on the button itself' do
    assert_includes last_response.body, "Import #{this_year}</button>"
    assert_includes last_response.body, "reads #{this_year} from Withings"
  end

  # So that a lifter with three years of history knows it is three presses rather than
  # wondering whether the first one worked.
  it 'says how many years are left to go and where they stop' do
    assert_includes last_response.body, '3 years to go,'
    assert_includes last_response.body, "back to #{this_year - 2}"
  end

  it 'posts through a form of its own with a token on it' do
    refute_nil token_for_form('/settings', '/settings/withings/import')
  end
end

describe 'pressing import once' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_history
    @asked = []
    press_recording(@asked)
  end

  # One year, and the newest first, which is the order the walk already keeps: a run cut
  # short has done the years whose sessions somebody can still remember well enough to
  # confirm. The rest wait for the next press rather than for a background worker.
  it 'reads exactly one year of history' do
    assert_equal [this_year], @asked
  end

  it 'says what it found, in the numbers the rake task reports' do
    assert_includes last_response.body, "#{this_year}: 0"
    assert_includes last_response.body, 'activities from your watch'
    assert_includes last_response.body, 'new proposals to answer'
    assert_includes last_response.body, 'no activity from your watch'
  end

  # Knowing whether to press again is half of what makes a slice per press honest. The other
  # half is being told when to stop, which the last press says instead.
  it 'says there is more history to fetch' do
    assert_includes last_response.body, 'There is more history to fetch'
    assert_includes last_response.body, "#{this_year - 1} and earlier"
  end

  it 'offers the year before on the next press' do
    assert_includes last_response.body, "reads #{this_year - 1} from Withings"
  end
end

describe 'pressing import until there is nothing left' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_history
    3.times { press(answering(@found)) }
  end

  # The year of the earliest stamped set is the floor, and it is a bound out of Tectonic's
  # own data: a year before the first logged session holds nothing that could ever be
  # proposed to anything.
  it 'stops offering to import once the earliest session year has been read' do
    assert_includes last_response.body, "imported back to #{this_year - 2}"
    refute_includes last_response.body, 'Import your history one year at a time'
  end

  it 'takes the button away rather than leaving one that would do nothing' do
    get '/settings'

    refute_match(%r{<form[^>]*action="/settings/withings/import"}, last_response.body)
  end

  # The point of the whole thing: the activity the walk found is offered to the session it
  # overlaps, and the lifter answers it on the screen that already exists for that.
  it 'has left the proposals it found waiting for an answer' do
    assert_equal @workout_id, proposals(@account_id).first[:proposed_workout_id]
    assert_nil proposals(@account_id).first[:workout_id]
  end
end

describe 'a press Withings refused to answer' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_history
    press(nil)
  end

  # The single most important behaviour in #558. Withings signal rate limiting as status 601
  # inside an ordinary HTTP 200, and `Withings.workouts` answers nil for a year it could not
  # read -- so a throttled year reaches the page looking exactly like a quiet one. Rendering
  # it as a row of zeroes would tell a lifter that year held no training and move them on to
  # the next, and the year they were actually refused would never be asked for again.
  it 'says Withings did not answer rather than reporting a year with nothing in it' do
    assert_includes last_response.body, 'Withings did not answer'
    refute_includes last_response.body, '0 activities from your watch'
  end

  it 'keeps the same year on the button so the press can simply be made again' do
    assert_includes last_response.body, "reads #{this_year} from Withings"
    assert_includes last_response.body, '3 years to go,'
  end

  # The cursor is what decides which year the next press reads, so moving it on a refusal is
  # how a year gets silently skipped. A cursor behind the truth costs one request to a year
  # already stored; a cursor ahead of it loses that year for good.
  it 'does not move the cursor past a year it never read' do
    assert_nil imported_year(@account_id)
  end
end

describe 'what a press does to the rake task that shares the walk' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_history
    press(answering(@found))
  end

  # #554, worked around deliberately. `attempt` stamps `workouts_backfilled_at` whenever the
  # years it chose to walk all answered, and a slice walks a narrowed range by construction --
  # so a press routed through `run(since:)` would stamp the watermark, `resumed_year` would
  # raise the floor to this year, and every later press and every later rake run would believe
  # the decade behind it had been read. One press, a claim of completeness, history gone.
  it 'leaves the rake task\'s watermark alone' do
    assert_nil connection(@account_id)[:workouts_backfilled_at]
  end

  it 'keeps its own cursor instead, naming the year it actually read' do
    assert_equal this_year, imported_year(@account_id)
  end

  # And the task still walks from the earliest stamped set, which is the regression a shared
  # watermark would have caused: the years a press has not reached must stay askable.
  it 'does not narrow the years the task would walk' do
    assert_equal years_from(@at.year), asked_for(@account_id)
  end
end

describe 'a press by somebody with nothing to import' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  # A history has nothing to be offered to until something has been logged here, and saying
  # so is different from offering a button that would walk a decade for nobody.
  it 'is told there is nothing to match against rather than being offered a year' do
    account_id = login
    connect(account_id)
    get '/settings'

    assert_includes last_response.body, 'Nothing has been logged here yet'
    refute_match(%r{<form[^>]*action="/settings/withings/import"}, last_response.body)
  end

  # The import control belongs to the connection, so an account that has never connected one
  # is told how to start and nothing else.
  it 'is not offered at all to somebody with no watch connected' do
    login
    get '/settings'

    refute_includes last_response.body, 'Import your history one year at a time'
  end
end

describe 'the gate in front of the import' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before { lifter_with_history }

  # The same gate the connect and disconnect forms beside it sit behind. A form on somebody
  # else's page must not be able to spend this account's Withings budget.
  it 'refuses a post with no token on it' do
    asked = []
    Tectonic::Withings.stub(:post, ->(_path, **_form) { asked << 1 }) { post '/settings/withings/import' }

    refute_equal 302, last_response.status
    assert_empty asked
  end

  it 'sends somebody who is not logged in to log in' do
    clear_cookies
    post '/settings/withings/import'

    assert_includes last_response.headers['Location'].to_s, '/login'
  end
end

describe 'a press that meets the stranded proposal #555 describes' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before { lifter_with_history }

  # A proposal left on a session that was answered elsewhere is never cleared, so a later run
  # can pick a second activity for that session and the update collides with the unique index
  # on `proposed_workout_id`. From a rake task that is a stack trace after the API budget is
  # spent; from a button it would be a 500 on the settings page of somebody who had just paid
  # for a year of requests. The year is stored either way, and the page says what could not be
  # finished rather than reporting four zeroes as though it had been.
  # An activity in the year this press actually reads, so there is something stored to be
  # honest about when the pairing afterwards falls over.
  def collides
    recent = activity(id: 'w-now', starts: Time.new(this_year, 3, 1, 10, 0, 0), minutes: 48)
    colliding = ->(_account_id) { raise Sequel::UniqueConstraintViolation, 'proposed_workout_id' }
    Tectonic::WithingsBackfill.stub(:pair, colliding) { press(answering(recent)) }
  end

  it 'does not reach the lifter as a 500' do
    collides

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'the matching could not be finished'
  end

  it 'still counts the year as read, because the activities were stored' do
    collides

    assert_equal this_year, imported_year(@account_id)
    assert_equal 1, DB[:withings_workouts].where(account_id: @account_id).count
  end
end

