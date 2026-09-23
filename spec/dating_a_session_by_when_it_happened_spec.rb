# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'query_count_spec' # and the tally that says whether a list reads per row
require 'rack/test'
require 'securerandom'
require 'date'

# Every page that names a session's date names the day it was trained. #572.
#
# #440 settled the rule -- display and report the performed date from `completed_at`, keep the
# stored date as the scheduled one -- and #479 built it. It built it for the calendar. Seven
# other renderings of a session's date went on reading `workouts.date` raw, which is the day a
# programme *wrote the session for*, and the reporting account trains ahead of its programme:
# a session performed on the 23rd was titled "Friday September 25, 2026" on its own record
# page, two days in the future, twice in a row.
#
# The dates below are the reported ones rather than arithmetic off today, because the bug is
# about two dates disagreeing and a spec that computes both from the same clock cannot show
# them disagreeing in a way anybody would recognise. They are fixed, so the run cannot land on
# a month boundary or a day whose name depends on when the suite is run.
module SessionDates
  PLANNED = Date.new(2026, 9, 25)   # a Friday: what the programme wrote
  PERFORMED = Date.new(2026, 9, 23) # a Wednesday: when it was actually lifted

  # A second session whose two dates disagree the other way about: written for the Monday
  # before the one above and trained the Thursday after it. One session cannot show that a
  # list is ordered by the wrong date -- any order of one row is every order of it -- and two
  # that merely differ cannot either, because plan order and training order would agree and
  # the list would look right whichever it used. These two are deliberately in opposite orders
  # under the two readings, so the review list can only satisfy one of them.
  OTHER_PLANNED = Date.new(2026, 9, 21)   # a Monday: written first, and trained last
  OTHER_PERFORMED = Date.new(2026, 9, 24) # a Thursday

  # A movement of this account's own, so nothing here depends on the shared library.
  def a_movement(account_id)
    DB[:exercises].insert(name: "Squat #{SecureRandom.hex(4)}", account_id:)
  end

  # A session written for one day and trained on another, which is the reported shape.
  # `trained_on: nil` leaves it untrained, which is the fallback case that has to survive.
  #
  # 18:00 rather than anything near midnight: `completed_at` is a timestamp without a zone,
  # so nothing converts it, but a stamp an hour from the end of a day is a spec that will
  # eventually be read as asking a question about zones. It is not asking one.
  def a_session(account_id, written_for: PLANNED, trained_on: PERFORMED, sets: 2)
    workout_id = DB[:workouts].insert(account_id:, date: written_for)
    exercise_id = a_movement(account_id)
    set_ids = Array.new(sets) do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: !trained_on.nil?,
                       completed_at: trained_on && Time.new(trained_on.year, trained_on.month,
                                                            trained_on.day, 18, 0, 0))
    end
    [workout_id, exercise_id, set_ids.first]
  end

  # A session with a question waiting on it: written for one day, trained on another, and an
  # activity the watch recorded inside the hour it was really trained. Written straight into
  # the tables rather than through a backfill, because what is being set up is the state a
  # backfill leaves and not the walk that leaves it -- and **nothing here calls Withings**,
  # which a walk would have to be stubbed to avoid.
  #
  # The activity starts a minute in and ends a minute short, so it sits inside the session
  # rather than straddling it -- an overlap nobody would call ambiguous, which is what these
  # claims want: they are about the date on a question, not about which question is asked.
  def a_question_waiting(account_id, written_for: PLANNED, trained_on: PERFORMED, watch: 'w-1')
    opened = Time.new(trained_on.year, trained_on.month, trained_on.day, 18, 0, 0)
    workout_id = a_trained_hour(account_id, written_for:, opened:)
    DB[:withings_workouts].insert(account_id:, external_id: watch, category: 16,
                                  started_at: opened + 60, ended_at: opened + 2940,
                                  proposed_workout_id: workout_id)
    workout_id
  end

  # The session underneath it, whose two stamps are fifty minutes apart rather than
  # `a_session`'s two at one instant. A proposal is only listed where the session has an
  # interval for the activity to overlap: `WithingsWorkouts.interval` refuses a window whose
  # two ends are the same moment, and `WithingsProposals.offered` drops a row whose evidence
  # it cannot state. That is also why the untrained fallback the rest of this file guards has
  # no case of its own on this screen -- a session nobody has trained has no interval, so it
  # never reaches the list at all, and there is nothing there to fall back from.
  def a_trained_hour(account_id, written_for:, opened:)
    workout_id = DB[:workouts].insert(account_id:, date: written_for)
    exercise_id = a_movement(account_id)
    [opened, opened + 3000].each do |at|
      DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                       is_completed: true, completed_at: at)
    end
    workout_id
  end

  # An account with `count` of them, each a day further back than the last, for the claim
  # about what a queue costs to draw rather than what it says.
  def questions_waiting(account_id, count)
    Array.new(count) do |index|
      a_question_waiting(account_id, written_for: PLANNED + index,
                                     trained_on: PERFORMED - index, watch: "w-#{index}")
    end
  end

  # Every date a page writes out for a person to read, and nothing else.
  #
  # The assertions below are about dates, so they are made against the dates rather than
  # against the page. `assert_includes body, 'Sep 23, 2026'` says the same thing and reports
  # it by printing forty kilobytes of HTML, which is a failure nobody reads -- and this is a
  # spec whose whole job is to be legible the next time somebody shows a session on the wrong
  # day. A list of three strings says which day it used instead.
  #
  # Three shapes because the app writes three: `%A %B %-d, %Y` on the record page, the set
  # list and a single set; `%A %b %-d` on the gym floor screen, which has a phone's width to
  # work in; and `%b %d, %Y` in the two tables. The `value="2026-09-25"` the edit form renders
  # is deliberately not one of them -- that is a form field rather than a sentence, and it is
  # asserted against the body directly where it matters.
  DATE_TEXT = /[A-Z][a-z]+day [A-Z][a-z]+ \d{1,2}(?:, \d{4})?|[A-Z][a-z]{2} \d{2}, \d{4}/

  def dates_on(path)
    get path
    last_response.body.scan(DATE_TEXT).uniq
  end

  def body_of(path)
    get path
    last_response.body
  end

  # The record page's line about the plan, or nil where it does not draw one. Found by the
  # sentence rather than by a class, because the class is styling and the sentence is the
  # feature -- a spec that asserted `text-gray-500` would go green on a page that had stopped
  # saying anything.
  def plan_note_on(path)
    body_of(path)[/Written for [^<.]+\./]
  end

  # What the page is titled, which on the record page is a narrower question than what dates
  # the page carries: it now names the plan underneath the heading on purpose, so "the record
  # page does not show the planned date" is no longer the thing to assert. "The heading is not
  # the planned date" is.
  def heading_on(path)
    body_of(path)[%r{<h1[^>]*>\s*(.*?)\s*</h1>}m, 1]
  end
end

# The six human-facing renderings, an example apiece rather than one sweep over all of them,
# because when this regresses it will regress on one page and the failure should say which.
# Grouped by what the fix had to do to each: the first four are single-session pages, where the
# date is read off one row that has already been fetched, and the last two are lists, where
# reading it per row would be an N+1 -- so those have spec/query_count_spec.rb behind them too.
describe 'a session trained two days before the day it was written for' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, @exercise_id, @set_id = a_session(@account_id)
  end

  it 'is titled on its record page with the day it was trained' do
    assert_equal 'Wednesday September 23, 2026', heading_on("/workouts/#{@workout_id}")
  end

  it 'is headed on the gym floor screen with the day it was trained' do
    assert_includes dates_on("/workouts/#{@workout_id}/session"), 'Wednesday Sep 23'
  end

  it 'is not headed on the gym floor screen with the day it was written for' do
    refute_includes dates_on("/workouts/#{@workout_id}/session"), 'Friday Sep 25'
  end
end

# The two sets pages, which name the session they belong to rather than being headed by it.
# The same rule again -- what is worth a describe of its own is that a set is reached from a
# list and from a link, and both of those have to land on a page whose date agrees with the
# one that was clicked.
describe 'the sets of a session trained before the day it was written for' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, @exercise_id, @set_id = a_session(@account_id)
  end

  it 'is subtitled on its set list with the day it was trained' do
    assert_includes dates_on("/workouts/#{@workout_id}/sets"), 'Wednesday September 23, 2026'
  end

  it 'is not subtitled on its set list with the day it was written for' do
    refute_includes dates_on("/workouts/#{@workout_id}/sets"), 'Friday September 25, 2026'
  end

  it 'is named on a single set page with the day it was trained' do
    assert_includes dates_on("/workouts/#{@workout_id}/sets/#{@set_id}"), 'Wednesday September 23, 2026'
  end

  it 'is not named on a single set page with the day it was written for' do
    refute_includes dates_on("/workouts/#{@workout_id}/sets/#{@set_id}"), 'Friday September 25, 2026'
  end
end

# The two lists. Same rule and the same session; what is different is that these render a date
# per row, so the date has to come out of the query that fetched the rows rather than out of a
# query per row. spec/query_count_spec.rb is what holds that half; these hold the date itself.
describe 'a session listed among others it was trained before' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, @exercise_id, @set_id = a_session(@account_id)
  end

  it 'is listed on the workouts list with the day it was trained' do
    assert_includes dates_on('/workouts'), 'Sep 23, 2026'
  end

  it 'is not listed on the workouts list with the day it was written for' do
    refute_includes dates_on('/workouts'), 'Sep 25, 2026'
  end

  # The one #572 calls the worst of them: a lifter's own record of what they lifted and when.
  it 'is dated in exercise history with the day it was trained' do
    assert_includes dates_on("/exercises/#{@exercise_id}"), 'Sep 23, 2026'
  end

  it 'is not dated in exercise history with the day it was written for' do
    refute_includes dates_on("/exercises/#{@exercise_id}"), 'Sep 25, 2026'
  end
end

# The seventh rendering, and the one #572 could not fix from a template. The two lists above
# are model rows a view dates; this one is a list `WithingsProposals.waiting` builds itself, so
# the date on the row and the order of the rows are both its decision and both were the stored
# one. A lifter meets these questions here, one after another, about sessions they have to
# recognise well enough to answer -- so a row headed with a day they did not train is a row
# they have to reconstruct before they can say yes to it.
describe 'a session the watch has a question waiting about' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    a_question_waiting(@account_id)
  end

  it 'is listed on the review list with the day it was trained' do
    assert_includes dates_on('/workouts/withings'), 'Sep 23, 2026'
  end

  it 'is not listed on the review list with the day it was written for' do
    refute_includes dates_on('/workouts/withings'), 'Sep 25, 2026'
  end
end

# And the order, which is not a side effect of the date but the other half of the same claim.
# A list labelled with one date and sorted by another is worse than one that is wrong about
# both, because the rows are then in an order nothing on screen explains: two questions dated
# the 23rd and the 24th, with the 23rd above. The queue is a sitting somebody works down, and
# the order that makes it one is the order they trained -- most recent first, because the
# sessions somebody can still remember are the ones they can answer quickly, and the
# archaeology is better met at the end than at the start.
describe 'the order the review list asks its questions in' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    a_question_waiting(@account_id)
    a_question_waiting(@account_id, written_for: SessionDates::OTHER_PLANNED,
                                    trained_on: SessionDates::OTHER_PERFORMED, watch: 'w-2')
  end

  # Asserted as the whole sequence rather than as "the 24th is present", because what is
  # wrong when this regresses is the relationship between the rows and not any one of them.
  it 'asks first about the session trained most recently' do
    assert_equal ['Sep 24, 2026', 'Sep 23, 2026'], dates_on('/workouts/withings')
  end
end

# The hazard the date on a list carries with it. `performed_on` answers from the row where the
# query selected it and otherwise goes and fetches it one session at a time, so a date drawn
# per row is an N+1 waiting for a loop to put it in -- which is exactly what this screen is.
# #572 found the same trap already sprung in exercise history, at a hundred queries on a large
# account, and nothing failed while it was.
describe 'what the review list costs to draw its dates' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates
  include QueryCount

  # Separate accounts rather than one that grows, like query_count_spec: the small case must
  # not be measured against a plan cache the large case warmed.
  it 'costs the same for twelve questions as for one' do
    questions_waiting(login, 1)
    one = queries_while { get '/workouts/withings' }
    questions_waiting(login, 12)
    twelve = queries_while { get '/workouts/withings' }

    assert_equal one, twelve, "the review list costs #{twelve} queries with twelve questions " \
                              "waiting and #{one} with one, so it is reading per proposal"
  end
end

# The fallback, which is the half of this that a careless fix breaks. A session nobody has
# trained has no performed date to read, and for one that has not happened yet the planned
# date is the right and only answer -- blanking it would be a worse bug than the one above.
describe 'a session nobody has trained yet' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, @exercise_id, @set_id = a_session(@account_id, trained_on: nil)
  end

  it 'is still titled on its record page with the day it is written for' do
    assert_equal 'Friday September 25, 2026', heading_on("/workouts/#{@workout_id}")
  end

  it 'is still headed on the gym floor screen with the day it is written for' do
    assert_includes dates_on("/workouts/#{@workout_id}/session"), 'Friday Sep 25'
  end

  it 'is still subtitled on its set list with the day it is written for' do
    assert_includes dates_on("/workouts/#{@workout_id}/sets"), 'Friday September 25, 2026'
  end

  it 'is still named on a single set page with the day it is written for' do
    assert_includes dates_on("/workouts/#{@workout_id}/sets/#{@set_id}"), 'Friday September 25, 2026'
  end

  it 'is still listed on the workouts list with the day it is written for' do
    assert_includes dates_on('/workouts'), 'Sep 25, 2026'
  end

  it 'is still dated in exercise history with the day it is written for' do
    assert_includes dates_on("/exercises/#{@exercise_id}"), 'Sep 25, 2026'
  end
end

# A session whose sets were completed before #281 gave them a stamp cannot say when it
# happened. The planned date is the best available answer rather than a guess, and the
# calendar has behaved this way since #479 -- the rest of the app now agrees with it.
describe 'a session completed with no stamp to read' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  it 'is titled with the day it was written for' do
    account_id = login
    workout_id, = a_session(account_id, trained_on: nil)
    DB[:sets].where(workout_id:).update(is_completed: true, completed_at: nil)

    assert_equal 'Friday September 25, 2026', heading_on("/workouts/#{workout_id}")
  end
end

# The stored date is the plan and stays the plan. This is a display fix: nothing here moves a
# row, and the edit form goes on editing the column rather than the derived date -- #530 made
# rescheduling safe and it has to stay that way.
describe 'the date a session stores' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, = a_session(@account_id)
  end

  it 'is untouched by showing the session' do
    get "/workouts/#{@workout_id}"

    assert_equal SessionDates::PLANNED, DB[:workouts].where(id: @workout_id).get(:date).to_date
  end

  it 'is what a page showing the trained date still holds' do
    get "/workouts/#{@workout_id}/session"

    assert_equal SessionDates::PLANNED, DB[:workouts].where(id: @workout_id).get(:date).to_date
  end
end

# Rescheduling is real and #530 made it safe, so the form edits the column rather than the
# reading of it. Nothing about #572 may reach this: the box has to open on the stored plan and
# post the stored plan back, or a lifter who renames a session moves it to the day they
# happened to train -- which is the damage #440 was opened about, arriving by a third route.
describe 'the form that reschedules a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  before do
    @account_id = login
    @workout_id, = a_session(@account_id)
  end

  it 'loads the stored plan into its date box' do
    assert_includes body_of("/workouts/#{@workout_id}/edit"), 'value="2026-09-25"'
  end

  it 'posts the stored plan back when nothing about the date is touched' do
    token = token_for("/workouts/#{@workout_id}/edit")
    post '/workouts', { 'id' => @workout_id.to_s, 'date' => '2026-09-25',
                        'name' => 'Squats', 'note' => '', '_csrf' => token }

    assert_equal SessionDates::PLANNED, DB[:workouts].where(id: @workout_id).get(:date).to_date
  end

  it 'writes the day it was given, rather than the day the session was trained' do
    token = token_for("/workouts/#{@workout_id}/edit")
    post '/workouts', { 'id' => @workout_id.to_s, 'date' => '2026-09-28',
                        'name' => '', 'note' => '', '_csrf' => token }

    assert_equal Date.new(2026, 9, 28), DB[:workouts].where(id: @workout_id).get(:date).to_date
  end
end

# And the part of this worth arguing about: a session shown under one date while storing
# another says so, on the one page that is the record of the session rather than a list of
# them. Silently showing one date and storing a different one is how #440 came to be closed
# twice.
describe 'a session shown under a day it was not written for' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionDates

  it 'says what the programme wrote it for' do
    account_id = login
    workout_id, = a_session(account_id)

    assert_equal 'Written for Friday September 25, 2026.', plan_note_on("/workouts/#{workout_id}")
  end

  it 'says nothing where the two agree' do
    account_id = login
    workout_id, = a_session(account_id, written_for: SessionDates::PERFORMED)

    assert_nil plan_note_on("/workouts/#{workout_id}")
  end

  it 'says nothing about a session nobody has trained' do
    account_id = login
    workout_id, = a_session(account_id, trained_on: nil)

    assert_nil plan_note_on("/workouts/#{workout_id}")
  end
end

