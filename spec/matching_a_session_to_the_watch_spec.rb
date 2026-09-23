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
  # week because an hour ago is inside `STILL_ARRIVING`, which is the only thing age decides
  # since #560: whether the box may say a watch upload might still be coming. Whether an
  # activity is *offered* no longer depends on it at all, and there are describes below for
  # both halves of that.
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
  #
  # `model` is on the response whether or not anything asked for it -- it is not a
  # `data_field` -- so it is out here beside `category` rather than under `data`, which is
  # the distinction 050 rests on. 59 is what Withings' own table calls an Activite Steel HR
  # Sport Edition, and the number is stored rather than that name.
  def activity(id: 'w-1', starts: Time.now - 3600, minutes: 50, category: 16, **extra)
    { 'id' => id, 'category' => category, 'timezone' => 'America/New_York',
      'attrib' => 0, 'startdate' => starts.to_i, 'enddate' => (starts + (minutes * 60)).to_i,
      'modified' => starts.to_i, 'model' => 59,
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

  # The page, opened after Withings has already sent whatever it was going to send.
  #
  # **A page view fetches nothing since #560**, so the activities have to be in the database
  # before the render rather than arriving during it -- which is what `store` does, and what
  # a press of check or a run of the backfill would have done earlier. Every assertion about
  # what the box says is therefore an assertion about stored rows, which is the whole of what
  # the record page now knows.
  def record(workout_id, found = [])
    @workout_id = workout_id
    found.each { |activity| Tectonic::WithingsWorkouts.store(@account_id, activity) }
    get "/workouts/#{workout_id}"
  end

  # Asking, which is the one thing on a record page that calls Withings at all. Presses the
  # form the box draws, with whatever Withings was going to answer stubbed, and follows the
  # redirect back to the record -- so what an assertion reads is the page a lifter lands on.
  #
  # `nil` is the answer meaning "Withings did not say" -- a throttle, a revoked grant, a
  # timeout -- and `[]` is the one meaning "Withings said there was nothing".
  def check_now(answer = [])
    Tectonic::Withings.stub(:workouts, answer) { press_check }
    follow_redirect!
  end

  # The press on its own, unstubbed, for the specs that want to watch what goes over the wire.
  def press_check
    action = "/workouts/#{@workout_id}/withings/check"
    post action, { '_csrf' => token_for_form("/workouts/#{@workout_id}", action) }
  end

  # How many requests something made, counted at the one door every Withings request goes
  # through. A count at `Withings.workouts` would keep passing the day a page started
  # reaching for a different method on the same service.
  def calls_while(&)
    calls = 0
    counting = lambda do |_path, **_form|
      calls += 1
      { 'series' => [] }
    end
    Tectonic::Withings.stub(:post, counting, &)
    calls
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

    refute_includes last_response.body, 'Was that this session?'
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

    refute_includes last_response.body, 'Was that this session?'
  end
end

# The half of #560 that is wording. `:waiting` covered two situations and its sentence --
# *"Nothing from Withings yet -- check back in a minute"* -- fits only one of them. The
# reporting account was in the other: two activities stored from that morning, neither
# overlapping the session on screen, and a page saying nothing had arrived.
module NoneOfThem
  include MatchingTheWatch

  def a_session_with_things_around_it
    @account_id = login
    connect(@account_id)
    @started_at = Time.now - 3600
    @workout_id = trained_session(@account_id, started_at: @started_at)
  end

  def a_walk(id: 'walk', before: 7200) = activity(id:, starts: @started_at - before, minutes: 30)
end

describe 'a session Withings has activities around but none of' do
  include Rack::Test::Methods
  include RouteOwnership
  include NoneOfThem

  before { a_session_with_things_around_it }

  # Something was recorded. Saying nothing arrived is false about a thing sitting in the
  # database, and the advice that follows from it -- wait and reload -- never pays off.
  it 'says what arrived rather than that nothing did' do
    record(@workout_id, [a_walk, activity(id: 'ride', starts: @started_at + 7200, minutes: 30)])

    assert_includes last_response.body, 'Withings has 2 activities around this session'
    refute_includes last_response.body, 'Nothing from Withings'
  end

  # One is one, not "1 activities". The count is read by a person.
  it 'counts one activity in the singular' do
    record(@workout_id, [a_walk])

    assert_includes last_response.body, 'Withings has one activity around this session'
  end
end

describe 'the activities that sentence is allowed to count' do
  include Rack::Test::Methods
  include RouteOwnership
  include NoneOfThem

  before { a_session_with_things_around_it }

  # An activity that overlaps but has been refused is not something this session may be
  # offered, so it is not in the count either -- "2 activities, none of them overlapping"
  # printed over a set containing one that does would be the same lie in a new place.
  it 'leaves out an overlapping activity the lifter has already refused' do
    record(@workout_id, [a_walk, activity(id: 'lift', starts: @started_at, minutes: 50)])
    DB[:withings_workouts].where(external_id: 'lift').update(dismissed_at: Time.now)
    get "/workouts/#{@workout_id}"

    assert_includes last_response.body, 'Withings has one activity around this session'
  end

  # A day either side is the span a fetch asks for, so it is the span the sentence reports
  # on. An activity from a fortnight ago was never part of the answer to this question.
  it 'does not count an activity from another week' do
    record(@workout_id, [a_walk(id: 'far', before: 14 * 24 * 3600)])

    assert_includes last_response.body, 'Nothing from Withings for this session yet'
  end
end

# The detail #568 asks for. #560's sentence is true -- something was recorded and it was not
# this session -- and a number on its own is not something a lifter can check, recognise or
# act on: which two, when, and was one of them this lift filed against the wrong clock.
#
# What is pinned here is the sentence itself, word for word, for a known pair of activities.
# An assertion that some words appear somewhere on a page would have passed happily on the
# sentence that prompted the complaint.
module WhatArrivedInstead
  include MatchingTheWatch

  # A session at a fixed time of day rather than "an hour ago", so that "the day before" is a
  # property of the fixture rather than of the clock the suite happens to run on. Today's
  # date, because the box only appears while an upload could still be coming -- STILL_ARRIVING.
  def a_session_at_ten_past_one
    @account_id = login
    connect(@account_id)
    @started_at = clock_on(Date.today, 13, 10)
    @workout_id = trained_session(@account_id, started_at: @started_at, minutes: 38)
  end

  # Built off the date rather than by subtracting 86_400 from a stamp, which lands on the day
  # before last twice a year: the hour a clock change removes is exactly the hour this would
  # otherwise borrow, and the spec would fail in October with nothing wrong with the app.
  def clock_on(date, hour, minute) = date.to_time + (hour * 3600) + (minute * 60)

  # Yesterday's two, which is the reporting account's own case: the watch's idea of a lift,
  # and a ride in the evening. Category 6 is the one the two-entry scoring table could not
  # name at all.
  def yesterday_pair
    [activity(id: 'lift', category: 16, starts: clock_on(Date.today - 1, 13, 13), minutes: 65),
     activity(id: 'ride', category: 6, starts: clock_on(Date.today - 1, 21, 17), minutes: 66)]
  end

  # The box as a lifter reads it: list markers kept, tags out, runs of whitespace closed up,
  # from its first word to its last. Whole rather than in fragments, because the complaint is
  # about what the box *says* and the parts of a sentence are not the sentence.
  #
  # A tag becomes a space, so a full stop written hard against a closing `</time>` -- which is
  # a full stop against a clock time on the page -- comes out of that with a space in front of
  # it. It is put back, because the alternative is an expectation containing "20:48 UTC ."
  # which would read as the thing being asserted rather than as an artefact of reading it.
  def box_says
    text = last_response.body.gsub('<li>', ' • ').gsub(/<[^>]+>/, ' ').gsub('&mdash;', '—')
    text.split.join(' ').gsub(' .', '.')[/Withings has .*?uploading this one\./]
  end

  # How _clock_time.erb prints an instant where no JavaScript has localised it. The four
  # clock times in these sentences are the fixture's own, read the way the page reads them;
  # every other word is pinned.
  def shown(date, hour, minute) = clock_on(date, hour, minute).utc.strftime('%H:%M UTC')
end

describe 'the activities a session did not match' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatArrivedInstead

  before { a_session_at_ten_past_one }

  it 'names them, times them, and says when the session itself ran' do
    record(@workout_id, yesterday_pair)
    yesterday = Date.today - 1

    assert_equal ['Withings has 2 activities around this session, and none of them overlaps it:',
                  "• Lift weights — the day before, #{shown(yesterday, 13, 13)} " \
                  "to #{shown(yesterday, 14, 18)}",
                  "• Bicycling — the day before, #{shown(yesterday, 21, 17)} " \
                  "to #{shown(yesterday, 22, 23)}",
                  "This session ran #{shown(Date.today, 13, 10)} to #{shown(Date.today, 13, 48)}.",
                  'So something was recorded and it was not this session. Checking again will',
                  'only help if your watch has not finished uploading this one.'].join(' '),
                 box_says
  end
end

describe 'which day an activity is said to be on' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatArrivedInstead

  before { a_session_at_ten_past_one }

  # Nothing at all where it shares the session's day: "today" beside a clock time is noise,
  # and it is a word that would be wrong on a record read back in March besides.
  it 'says no day for one from the session own day' do
    record(@workout_id, [activity(id: 'walk', category: 1, starts: clock_on(Date.today, 7, 0),
                                  minutes: 30)])

    assert_includes box_says, "• Walk — #{shown(Date.today, 7, 0)} to #{shown(Date.today, 7, 30)}"
    refute_includes box_says, 'the day'
  end
end

describe 'a category the scoring table never had a word for' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatArrivedInstead

  # The reporting account's second activity is category 6, and the whole naming table was
  # `{ 16 => ..., 17 => ... }` because scoring only ever asked whether a row looked like
  # lifting. A box that cannot name what it is listing is the complaint again in a new place.
  it 'is named from the table Withings publishes' do
    a_session_at_ten_past_one
    record(@workout_id, [yesterday_pair.last])

    assert_includes box_says, '• Bicycling — the day before,'
  end

  # And an id that table does not carry prints as an id. "Other" or "Activity" would read as
  # something the lifter had tapped in Health Mate, which is inventing a name for a row.
  #
  # 533 rather than 306, which this asserted until #579. 306 was the worked example of an
  # unnameable id and it is "Indoor walk" -- the mirrors #568 transcribed from were missing
  # it, so the spec encoded the gap as though it were Withings'. 533 is a number inside the
  # published range that the published table genuinely skips.
  it 'prints the id where Withings has published no name' do
    a_session_at_ten_past_one
    record(@workout_id, [activity(id: 'odd', category: 533, starts: clock_on(Date.today - 1, 9, 0),
                                  minutes: 30)])

    assert_includes box_says, '• Withings category 533 — the day before,'
  end

  # The other half of the same correction, on the page rather than on the constant: 306 is a
  # category a lifter can be shown a name for and was being shown a number for.
  it 'names the indoor walk it used to print a number for' do
    a_session_at_ten_past_one
    record(@workout_id, [activity(id: 'indoors', category: 306, starts: clock_on(Date.today - 1, 9, 0),
                                  minutes: 30)])

    assert_includes box_says, '• Indoor walk — the day before,'
  end
end

describe 'a watch that recorded ten things that day' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatArrivedInstead

  before { a_session_at_ten_past_one }

  # A box under a session on a phone, not a log. Ten lines would push the controls below the
  # fold and be a second way of being unreadable -- but three of ten shown in silence would
  # be the same withholding #568 is about, so the rest are counted.
  def crowd(count) = (1..count).map { |n| walk(n) }

  def walk(number)
    activity(id: "a-#{number}", category: 1, minutes: 20,
             starts: clock_on(Date.today - 1, 6, 0) + (number * 3600))
  end

  it 'names three of them and counts the rest' do
    record(@workout_id, crowd(10))

    assert_includes box_says, 'Withings has 10 activities around this session'
    assert_equal 3, box_says.scan('• Walk').length
    assert_includes box_says, '• and 7 more around this session'
  end

  # The three are the three nearest the session, which is the same measure `best` breaks its
  # ties with: an activity from twenty minutes after the last set is the one most likely to
  # be this lift filed against a clock that disagrees, and it must not be what falls off.
  it 'keeps the one nearest the session rather than the ones read first' do
    record(@workout_id, crowd(9) + [activity(id: 'close', category: 6, minutes: 20,
                                             starts: @started_at + 3600)])

    assert_includes box_says, '• Bicycling'
  end
end

describe 'what listing the activities costs' do
  include Rack::Test::Methods
  include RouteOwnership
  include WhatArrivedInstead

  before { a_session_at_ten_past_one }

  # #560's central claim, held over the box that now says more. Detail comes from rows that
  # are already stored, so a page that names two activities makes exactly as many requests as
  # one that names none.
  it 'asks Withings for nothing at all' do
    record(@workout_id, yesterday_pair)

    asked = calls_while { get "/workouts/#{@workout_id}" }

    assert_equal 0, asked
    assert_includes box_says, '• Lift weights'
  end
end

describe 'what the app calls a Withings category' do
  # One table for names and another for what counts as lifting, because one table doing both
  # is how "is 17 lifting" and "what is 17 called" come to be answered from the same place
  # and then drift.
  it 'uses the name Withings publishes' do
    assert_equal 'Bicycling', Tectonic::WithingsWorkouts.called(6)
  end

  # 17 is "Fitness", which is what Withings' own OpenAPI document says and what 042's comment
  # has said since the table landed. This spec asserted "Calisthenics" -- the name both of the
  # community mirrors #568 transcribed from carry -- so the wrong name was pinned here as well
  # as stored in the constant, and the repo contradicted itself in three places rather than
  # two. #579 read the primary source; the method is in the comment on `CATEGORIES`.
  #
  # The string is shown to a lifter as the watch's own word for what they did, so it has to be
  # the watch's word and not a mirror's guess at it.
  it 'calls 17 what Withings calls it rather than what a mirror called it' do
    assert_equal 'Fitness', Tectonic::WithingsWorkouts.called(17)
  end

  # 193 and 194 were left out entirely because the mirrors had them the other way round. They
  # are the right way round here, from the source, and the order is the whole content of it.
  it 'tells hockey from ice hockey, in the order Withings publishes them' do
    assert_equal 'Hockey', Tectonic::WithingsWorkouts.called(193)
    assert_equal 'Ice hockey', Tectonic::WithingsWorkouts.called(194)
  end

  # A real tag that a lifter can tap, and the one word `called` may never invent for an id it
  # does not recognise -- which is why it mattered that it was missing.
  it 'names the category Withings actually calls Other' do
    assert_equal 'Other', Tectonic::WithingsWorkouts.called(36)
  end
end

describe 'a category Withings has published no name for' do
  # Withings allocate ids as they add activities and do not reuse retired ones, so the
  # published table has gaps in it -- there is no 37 through 127, and no 533. The honest
  # answer for one of those is the number, which is also the one thing that makes the gap
  # fixable if it ever turns out not to be a gap.
  #
  # This asserted 306 until #579, on the strength of a table transcribed from mirrors that
  # were missing it. 306 is "Indoor walk", which is why the example had to move.
  it 'is the id and nothing more' do
    assert_equal 'Withings category 533', Tectonic::WithingsWorkouts.called(533)
  end

  # The id the fallback used to be demonstrated with, named.
  it 'is not what happens to 306, which Withings does publish' do
    assert_equal 'Indoor walk', Tectonic::WithingsWorkouts.called(306)
  end

  it 'is said plainly where Withings sent no category at all' do
    assert_equal 'An activity Withings did not name', Tectonic::WithingsWorkouts.called(nil)
  end
end

describe 'the category a proposal sentence names' do
  include MatchingTheWatch

  # That sentence is the score said in words, so it names the tag only where the tag scored
  # the quarter. "Withings called it bicycling" under an offer would name a label that
  # contributed nothing to the offer and read as though it had.
  it 'leaves out one that scored nothing' do
    riding = row(starts_offset: 2, minutes: 48, category: 6)

    assert_equal 'overlaps this session for 48m of its 52m',
                 Tectonic::WithingsWorkouts.because(riding, window)
  end

  # Downcased, because it is read mid-sentence. 17 is in `LIFTING` exactly as it was before
  # #579 -- correcting its name moved no id -- so what changed here is the word and nothing
  # about which activities score the quarter.
  it 'names one that scored, in Withings own word for it' do
    bodyweight = row(starts_offset: 2, minutes: 48, category: 17)

    assert_equal 'overlaps this session for 48m of its 52m, and Withings called it fitness',
                 Tectonic::WithingsWorkouts.because(bodyweight, window)
  end

  # The correction the sentence must not have swallowed: 17 still scores, whatever it is
  # called. A rename that quietly dropped it out of `LIFTING` would show up as a lift losing
  # to a walk, months later, with nothing on screen to say why.
  it 'still counts 17 as looking like lifting under its corrected name' do
    bodyweight = row(starts_offset: 2, minutes: 48, category: 17)

    assert_includes Tectonic::WithingsWorkouts::LIFTING, 17
    assert_in_delta 0.25, Tectonic::WithingsWorkouts.score(bodyweight, window) -
                          Tectonic::WithingsWorkouts.score(bodyweight.merge(category: 6), window), 0.001
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

    assert_includes last_response.body, 'Nothing from Withings for this session yet'
    refute_includes last_response.body, 'No activity'
  end

  # A lifter who simply did not wear the watch has nothing to confirm, and would otherwise
  # be told to check back in a minute every time they opened the page.
  it 'can still be dismissed, because there is nothing coming for this session' do
    record(@workout_id, [])

    assert_includes last_response.body, 'withings/dismiss'
  end

  # #560's first half: the box told somebody to check and gave them nothing to check with,
  # so the only control on screen was the irreversible one.
  it 'offers a way to check, which is what the sentence asks for' do
    record(@workout_id, [])

    assert_includes last_response.body, "/workouts/#{@workout_id}/withings/check"
    assert_includes last_response.body, 'Check Withings now'
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

  # Absence and lateness are different, which is #520's rule and the reason `STILL_ARRIVING`
  # still exists after #560 took its other job away. For a session from last March there is
  # no upload on its way, so "nothing yet" is a hedge borrowed from a case that does not
  # apply, and silence is the honest rendering.
  it 'says nothing at all about an old session with nothing overlapping it' do
    connect(@account_id)
    old = trained_session(@account_id, started_at: Time.now - (30 * 3600))
    record(old, [activity(starts: Time.now - (30 * 3600) - 7200, minutes: 30)])

    refute_includes last_response.body, 'Nothing from Withings'
    refute_includes last_response.body, 'Was that this session?'
  end

  # **And the widening #560 asks for.** The old 24-hour bound was there to stop browsing a
  # year of training becoming a year of API calls; a page view makes none now, so a stored
  # activity is offered whatever the session's age. This is the reporting account's case
  # exactly: an activity from yesterday, overlapping a session that has passed a day old,
  # sitting unproposed for no reason but the clock.
  it 'still proposes a stored activity that overlaps a session from yesterday' do
    connect(@account_id)
    started_at = Time.now - (30 * 3600)
    old = trained_session(@account_id, started_at:)
    record(old, [activity(starts: started_at + 360, minutes: 45)])

    assert_includes last_response.body, 'Was that this session?'
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

# A session that has been answered yes, and the page as it looked before the answer. Split
# out of the describes below for the reason the rest of this file is split: the linter counts
# lines in a block, and two claims -- what a match leaves alone, and what it adds -- are two
# describes rather than one long one.
module AfterYes
  include SayingYes

  # The session is 52 minutes of taps and the activity is 48 minutes of watch, so a page that
  # defers is visibly a different page and one that does not is byte for byte the same one.
  def a_confirmed_match
    a_session_with_an_offer
    @unmatched = duration_line
    answer('match', 'activity' => 'w-1')
    record(@workout_id, [])
  end

  # The paragraph that answers "how long did this take". Found by the classes it is drawn
  # with, because nothing else on the record page identifies it and a hook put in the markup
  # for a test's benefit would be a fixture shipped to production. A miss would make the
  # comparison below pass by comparing nil to nil, so it is refused here instead.
  def duration_line
    line = last_response.body[%r{<p class="mt-2 text-sm text-gray-500">(.*?)</p>}m, 1]

    refute_nil line, 'the record page no longer draws its duration line where this spec looks'
    line.split.join(' ')
  end
end

describe 'what a confirmed match leaves exactly as it was' do
  include Rack::Test::Methods
  include RouteOwnership
  include AfterYes

  before { a_confirmed_match }

  # The reversal, pinned. #571.
  #
  # #520 ruled that "where the two disagree about how long a session took, the watch is
  # right", and #528 printed the watch's 48m over the session's 52m. The reporting account's
  # own data says the watch starts late and runs long -- 6:13 to 7:18 against a session of
  # 6:07 to 6:53 -- so deferring redisplayed a 46 minute session as an hour, over the top of
  # the right answer.
  #
  # Said as a comparison rather than as a string, because the claim is not "the page says
  # 52m": it is that answering yes changes *nothing* about how long the session is reported
  # to have taken. A spec naming the figure would go on passing the day a match started
  # quietly swapping one number for another that happened to read the same.
  it 'leaves the session the length its own taps measured' do
    assert_equal @unmatched, duration_line
  end

  # And the hedge #528 added goes with it. It was there because a watch figure stood beside
  # this one and a reader needed to know which instrument each came from; with nothing
  # competing, it only makes a plain measurement sound unsure of itself.
  it 'stops hedging the length, because nothing stands beside it to be confused with' do
    refute_includes last_response.body, 'from your taps'
    refute_includes last_response.body, 'measured by your watch'
  end

  # The two ends deferred for the same reason the length did, and come back for the same
  # reason. The watch's start is a minute after the session's, which is what makes these two
  # assertions different assertions.
  it 'keeps the two ends its own taps measured' do
    assert_includes last_response.body, %(data-local="#{@started_at.to_i}")
    refute_includes last_response.body, 'on your watch'
  end
end

describe 'what a confirmed match adds, which is what only the watch knows' do
  include Rack::Test::Methods
  include RouteOwnership
  include AfterYes

  before { a_confirmed_match }

  # The whole remaining case for matching at all, and no arithmetic on taps will ever
  # produce it. All three figures, because an average of 128 over a session that ran 61 to
  # 164 is interval work and the same average over one that ran 120 to 136 is a grind.
  it 'shows the heart rate, which only the watch has' do
    assert_includes last_response.body, '128 bpm average, 61 to 164'
  end

  # Not thrown away either. It is stored, it is real, and it is the interval the overlap was
  # computed from, so a lifter wondering why their watch says otherwise is owed the answer --
  # named as the watch's recording, and nowhere near the lines that are the session's.
  it 'still shows what the watch itself recorded, labelled as the watch and not the session' do
    assert_includes last_response.body, 'Your watch&rsquo;s own recording ran'
    assert_includes last_response.body, '(48m)'
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

# 050, and #579's accounting for why it is worth a column: `model` arrives on every response
# without being asked for and was thrown away on every fetch, so nothing here could say which
# instrument recorded a session. It is out at the top level of the workout object rather than
# under `data`, which is what makes it free -- no `data_field`, no extra request, no scope.
describe 'which device recorded the activity' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  before do
    @account_id = login
    connect(@account_id)
    @workout_id = trained_session(@account_id)
  end

  it 'is kept rather than discarded with the rest of the response' do
    record(@workout_id, [activity])

    assert_equal 59, stored(@account_id).first[:model]
  end

  # An activity somebody typed into the Withings app has no instrument to name, and Withings
  # number their models from 1 -- so nil is the answer and 0 would be a model nobody owns.
  it 'is nothing rather than zero where there was no device' do
    record(@workout_id, [activity.merge('model' => nil)])

    assert_nil stored(@account_id).first[:model]
  end

  # The integer and not a name for it. Resolving 59 to "Activite Steel HR Sport Edition" on
  # the way in would freeze today's reading of somebody else's growing list into stored rows,
  # which is the argument 042 already made about `category`.
  it 'is the number Withings sent rather than a name for it' do
    record(@workout_id, [activity])

    assert_kind_of Integer, stored(@account_id).first[:model]
  end

  # A re-fetch is Withings' to overwrite here, unlike the lifter's answer: a watch replaced
  # between one fetch and the next is new information and the upsert should take it.
  it 'keeps up with a device that changed between fetches' do
    record(@workout_id, [activity])
    record(@workout_id, [activity.merge('model' => 1058)])

    assert_equal 1058, stored(@account_id).first[:model]
  end
end

describe 'the epochs Withings sends' do
  include Rack::Test::Methods
  include RouteOwnership
  include MatchingTheWatch

  # Turned into instants on the way in, so that no reader has to remember to convert and
  # none of them can forget.
  it 'are stored as instants' do
    @account_id = login
    connect(@account_id)
    starts = Time.now - 3600
    record(trained_session(@account_id), [activity(starts:)])

    assert_in_delta starts, stored(@account_id).first[:started_at], 1
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

  # The app reads; the watch is the instrument. #520. Asserted over the route rather than
  # over the module, because the route is where a write would be added by accident.
  it 'never asks Withings to write anything' do
    @workout_id = trained_session(@account_id)
    actions = []
    answering = lambda do |_path, **form|
      actions << form[:action]
      { 'series' => [] }
    end
    Tectonic::Withings.stub(:post, answering) { press_check }

    assert_equal %w[getworkouts], actions.uniq
  end
end

# Pressing check, which since #560 is the one thing on a record page that calls Withings.
module PressingCheck
  include MatchingTheWatch

  def a_session_to_ask_about
    @account_id = login
    connect(@account_id)
    @started_at = Time.now - 3600
    @workout_id = trained_session(@account_id, started_at: @started_at)
  end
end

describe 'a lifter asking Withings about one session' do
  include Rack::Test::Methods
  include RouteOwnership
  include PressingCheck

  before { a_session_to_ask_about }

  it 'asks Withings, which nothing else on the page does' do
    asked = calls_while { press_check }

    assert_equal 1, asked
  end

  it 'stores what came back' do
    check_now([activity(starts: @started_at)])

    assert_equal 1, stored(@account_id).length
  end

  # The point of pressing it. The proposal is on the page a press lands on, not on a page
  # the lifter has to think to reload.
  it 'proposes the activity it just fetched, on the page it lands on' do
    check_now([activity(starts: @started_at)])

    assert_includes last_response.body, 'Was that this session?'
  end

  # A press is a question, and a question is owed an answer. Without this the page after a
  # fetch that found nothing is byte for byte the page before it.
  it 'says it checked, so an empty answer is not a silently identical page' do
    check_now([])

    assert_includes last_response.body, 'Checked just now'
  end
end

describe 'a press Withings never answered' do
  include Rack::Test::Methods
  include RouteOwnership
  include PressingCheck

  before { a_session_to_ask_about }

  # The trap. Withings signals rate limiting as body status 601 over HTTP 200, and
  # `Withings.answered` folds that into the same nil as a revoked token -- so a throttled
  # press arrives looking exactly like an empty one. Reporting it as "nothing arrived" would
  # assert something about an afternoon the app never managed to ask about.
  it 'says Withings could not be reached rather than that nothing arrived' do
    check_now(nil)

    assert_includes last_response.body, 'could not be reached'
    refute_includes last_response.body, 'Checked just now'
  end

  # The old unreachable box offered no dismiss, on the grounds that dismissing answers a
  # question the app had failed to ask. That reasoning does not survive the fetch moving
  # behind a press: this is the box about the session with a note about a press on it, and
  # "stop asking about this one" is the lifter's to say either way.
  it 'still lets the session be dismissed' do
    check_now(nil)

    assert_includes last_response.body, 'withings/dismiss'
  end
end

describe 'a press nobody is entitled to make' do
  include Rack::Test::Methods
  include RouteOwnership
  include PressingCheck

  before { a_session_to_ask_about }

  # A write behind a post, so it takes a token like the yes and the no beside it.
  it 'is refused without a CSRF token' do
    asked = calls_while { post "/workouts/#{@workout_id}/withings/check" }

    assert_equal 0, asked
    refute_equal 302, last_response.status
  end

  # Somebody else's session is somebody else's, and a fetch against it would be this
  # account's token asked about a window it has no business knowing.
  it 'cannot be made against a session belonging to somebody else' do
    stranger, = strangers_workout
    asked = calls_while { post "/workouts/#{stranger}/withings/check" }

    assert_equal 0, asked
  end

  # The outcome rides back in the query string, so what reaches the page is whatever is in a
  # URL. It is matched against a fixed pair rather than printed.
  it 'says nothing about a checked value nobody recognises' do
    get "/workouts/#{@workout_id}?checked=<script>alert(1)</script>"

    refute_includes last_response.body, 'alert(1)'
    refute_includes last_response.body, 'Checked just now'
  end
end

# **The central claim of #560.** A record page is a page about a session, and until now
# opening one inside the 24-hour window put a Withings request with a ten-second timeout in
# front of the render -- so the slowest thing on the page was somebody else's service, and
# the number of calls the app made was however many times a lifter reloaded.
#
# Counted at `Withings.post`, which is the one door every request goes through, rather than
# at `Withings.workouts`: a count at the method the page happens to call today would keep
# passing if the page started calling a different one tomorrow.
describe 'what an ordinary view of a record page costs' do
  include Rack::Test::Methods
  include RouteOwnership
  include AskingWithings

  before do
    @account_id = login
    connect(@account_id)
  end

  it 'asks Withings for nothing at all' do
    workout_id = trained_session(@account_id)

    asked = calls_while { get "/workouts/#{workout_id}" }

    assert_equal 0, asked
  end

  # Including the case the old window existed for: a session finished ten minutes ago is
  # exactly the one that used to fetch on every view.
  it 'asks for nothing even for a session that has only just finished' do
    workout_id = trained_session(@account_id, started_at: Time.now - 600, minutes: 5)

    asked = calls_while { get "/workouts/#{workout_id}" }

    assert_equal 0, asked
  end

  # And a reload is a reload. Three views used to be three fetches.
  it 'asks for nothing however many times the page is opened' do
    workout_id = trained_session(@account_id)

    asked = calls_while { 3.times { get "/workouts/#{workout_id}" } }

    assert_equal 0, asked
  end
end

# A loop condition somebody else controls, in the two ways it can fail to end. Found live by
# review: it pinned a Puma thread behind a record page and hammered Withings until something
# killed the process.
describe 'a window Withings says is finished with a number' do
  # `0` is truthy in Ruby, and Withings documents `more` as a number. A quiet year answering
  # `more: 0` therefore read as "there is another page", came with `offset: 0`, and the loop
  # asked for the same page until something killed it -- a pinned Puma thread behind a record
  # page, or a rake task hammering somebody else's service. The specs above only ever fed it
  # `true` and `false`, which is how it survived.
  it 'stops when Withings says there are no more with a number rather than a boolean' do
    asked = 0
    answering = lambda do |_path, **_form|
      asked += 1
      raise 'asked for the same page far too many times' if asked > 5

      { 'series' => [{ 'id' => 1 }], 'more' => 0, 'offset' => 0 }
    end
    found = Tectonic::Withings.stub(:post, answering) do
      Tectonic::Withings.workouts('access-1', from: Date.today, to: Date.today)
    end

    assert_equal 1, asked, 'a quiet window was read as having another page'
    found_ids = found.map { |page| page['id'] }

    assert_equal [1], found_ids
  end
end

# And the bound, for the case the check above cannot catch: a provider that keeps saying there
# is more and keeps handing back the same offset. A loop somebody else ends needs a stop of our
# own, which is the argument WithingsMeasures already made for its own ceiling.
describe 'a provider that never says it is finished' do
  it 'gives up rather than following it forever' do
    asked = 0
    answering = lambda do |_path, **_form|
      asked += 1
      { 'series' => [{ 'id' => asked }], 'more' => 1, 'offset' => 0 }
    end
    found = Tectonic::Withings.stub(:post, answering) do
      Tectonic::Withings.workouts('access-1', from: Date.today, to: Date.today)
    end

    assert_equal Tectonic::Withings::MAX_PAGES, asked
    assert_nil found, 'a window that was never fully read was handed back as though it were whole'
  end
end

