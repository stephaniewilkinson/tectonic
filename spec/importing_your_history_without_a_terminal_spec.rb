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

  # The same lifter with seven years behind them, which is what #566 needs: a history long
  # enough that a course of presses can finish inside one calendar year and still leave
  # several years of calendar standing above where it stopped.
  def lifter_with_a_long_history
    @account_id = login
    connect(@account_id)
    @at = Time.new(this_year - 7, 6, 15, 10, 0, 0)
    @workout_id = session_in(this_year - 7, @account_id)
    @found = activity(starts: @at + 60, minutes: 48)
  end

  # A course of presses made in an earlier calendar year, which is the whole shape of #566.
  #
  # Moving the clock rather than writing the cursor by hand, because what is being asserted is
  # that a course of *ordinary presses* leaves a state the page can still read honestly years
  # later -- and a fixture that wrote the columns itself would be asserting against this
  # module's idea of them rather than against what pressing the button actually does.
  def pressed_in(year, times)
    Date.stub(:today, Date.new(year, 6, 1)) { times.times { press(answering(@found)) } }
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

  # #554. One press reads one year, and must not let the rake task believe the years behind it
  # have been read. The task now resumes off the range a press writes (#600), and only where
  # that range reaches the first session -- which one press of this year does not.
  it 'leaves the rake task walking back to the first session' do
    assert_equal this_year - 2, Tectonic::WithingsBackfill.years_to_walk(@account_id, nil).last
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

# #566, which is the import button's own hole and predates the cursor being shared.
#
# A cursor is one number and it answers one question: how far back the reading got. The page
# was reading it as the answer to a second question as well -- whether everything above it had
# been read -- and that is true for exactly as long as it takes the calendar to move on. A
# lifter who pressed Import through 2023 and stopped at 2019 was told in 2026 that their
# history was fully imported, while 2024 and 2025 had never been asked about and never would
# be, because the cursor sits below them and only ever moves further down.
describe 'a lifter who imported their whole history and came back some years later' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_a_long_history
    pressed_in(this_year - 3, 5)
    get '/settings'
  end

  # The failure in one line. Five presses in an earlier year read that year down to the
  # earliest stamped set, so the cursor is at the floor -- and the floor is the one place a
  # single number is read as "there is nothing left", whatever the calendar has done since.
  it 'is offered the years that happened after the course of presses ended' do
    assert_includes last_response.body, "Import #{this_year - 2}</button>"
    refute_includes last_response.body, 'imported back to'
  end

  # The wording is part of the fix. A sentence built around a single unbroken run backwards
  # cannot say this at all, and a page that cannot say it can only stay quiet about years
  # nobody has read.
  it 'names the years nobody has read rather than claiming the history is complete' do
    assert_includes last_response.body, "#{this_year - 2} to #{this_year} have not been read."
  end

  it 'says what it has read, now that the read range is two numbers rather than one' do
    assert_includes last_response.body, "Imported so far: #{this_year - 7} through #{this_year - 3}."
  end

  # "Back to" is the wrong direction for work that runs forwards. Everything older has been
  # read, so what is left is the years since, and the count has to stop pointing at the floor.
  it 'counts the years left forwards, because there is nothing older left to read' do
    assert_includes last_response.body, '3 years to go,'
    assert_includes last_response.body, 'up to this year.'
    refute_includes last_response.body, "back to #{this_year - 7}"
  end
end

describe 'a course of presses interrupted in one year and resumed in another' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  # Two presses and then nothing for three years, which leaves the gap in the middle rather
  # than at the top: unread years above what was read and unread years below it.
  before do
    lifter_with_a_long_history
    pressed_in(this_year - 3, 2)
    get '/settings'
  end

  # Newest first is the order this module already keeps, and between the two gaps it still
  # holds: the years above the read range are the newer ones, so they go first.
  it 'offers the newest unread year rather than carrying on below where it stopped' do
    assert_includes last_response.body, "Import #{this_year - 2}</button>"
  end

  it 'says both what has been read and what has not' do
    assert_includes last_response.body, "Imported so far: #{this_year - 4} through #{this_year - 3}."
    assert_includes last_response.body, "#{this_year - 2} to #{this_year} have not been read."
  end

  # Six: three above the read range and three below it. A count that only looked downwards
  # would say three and be wrong by exactly the years #566 is about.
  it 'counts every year still to go, on both sides of what it has read' do
    assert_includes last_response.body, '6 years to go,'
    assert_includes last_response.body, "back to #{this_year - 7}."
  end
end

describe 'how the page names a gap of one year and a gap of two' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before { lifter_with_a_long_history }

  it 'says one year has not been read' do
    pressed_in(this_year - 1, 1)
    get '/settings'

    assert_includes last_response.body, "#{this_year} has not been read."
  end

  it 'names both of them when there are two' do
    pressed_in(this_year - 2, 1)
    get '/settings'

    assert_includes last_response.body, "#{this_year - 1} and #{this_year} have not been read."
  end

  # A press reads one year, so a range of one year is the ordinary state after the first
  # press and "2025 through 2025" is a sentence nobody writes.
  it 'names a read of a single year as one year rather than a range of it' do
    pressed_in(this_year - 1, 1)
    get '/settings'

    assert_includes last_response.body, "Imported so far: #{this_year - 1}."
  end
end

describe 'pressing import to catch up the years since an old course of presses' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_a_long_history
    pressed_in(this_year - 3, 5)
  end

  # Upward through the gap rather than downward from this year, which is the one thing two
  # numbers can record: a range that stays in one piece. Reading this year first would leave
  # two disjoint pieces and no honest way to write the second one down.
  it 'reads the oldest unread year first, so what has been read stays in one piece' do
    asked = []
    press_recording(asked)

    assert_equal [this_year - 2], asked
  end

  it 'says the recent years are still unread rather than offering the history below' do
    press(answering(@found))

    assert_includes last_response.body, "#{this_year - 1} is next"
    refute_includes last_response.body, 'and earlier'
  end

  # And a press in the gap must claim the year it read and not the years above it, which is
  # the same mistake #566 is, made one year at a time.
  it 'does not claim the years above the one it just read' do
    press(answering(@found))
    get '/settings'

    assert_includes last_response.body, "Import #{this_year - 1}</button>"
  end
end

describe 'the last of the years an old course of presses left behind' do
  include Rack::Test::Methods
  include RouteOwnership
  include ImportingHistory

  before do
    lifter_with_a_long_history
    pressed_in(this_year - 3, 5)
    3.times { press(answering(@found)) }
  end

  # Only now, and this is the claim the page could not previously make honestly: the history
  # is read from the earliest stamped set through to this year, both ends of it written down.
  it 'says the history is complete, once there is genuinely nothing left either way' do
    assert_includes last_response.body, 'That was the last year; your history is fully imported.'
    refute_match(%r{<form[^>]*action="/settings/withings/import"}, last_response.body)
  end

  it 'says so again on the page after it, rather than only in the report' do
    get '/settings'

    assert_includes last_response.body, "imported back to #{this_year - 7}"
    assert_includes last_response.body, 'and forward to this year'
  end
end

