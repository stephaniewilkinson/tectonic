# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'reading_the_scale_spec' # ScaleReadings, and through it mcp_spec's mint/call_tool
require_relative '../lib/tectonic/withings'
require_relative '../lib/tectonic/withings_connection'
require_relative '../lib/tectonic/withings_measures'
require_relative '../lib/tectonic/withings_sleep'
require 'securerandom'
require 'bigdecimal'

# Reading how long the lifter slept the night before a session. #579.
#
# Nothing here talks to Withings, on `fetching_from_the_scale_spec`'s grounds: you cannot test
# somebody else's API, only this app's handling of what it sends back, and a spec that reached
# the real one would fail on a runner with no credentials. The stub sits on `Withings.post`,
# one layer below `Withings.sleep_summaries`, so the parameters the request is actually built
# from -- the path, the action, the `data_fields` opt-in, the bearer token -- are asserted
# rather than assumed. Stubbing the higher method would have pinned this file's idea of the
# request instead of the app's.
#
# What is worth asserting is the handful of things that are genuinely easy to get wrong: the
# seconds-to-hours arithmetic, which end of the night the row is filed at, the difference
# between a fetch that failed and a week with no nights in it, and -- the one this whole piece
# exists for -- that a sleep read moves its own watermark and never the measurement poll's.
module NightsSleep
  # An account with no web request behind it. Nothing in the first half of this file is a
  # route, so signing one in would only be a slower way to get an id.
  def an_account
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: 'not-a-real-hash')
  end

  # A connection, optionally one that has had its sleep read before. `synced_at` and
  # `measures_read_back_to` are set alongside so that the watermark specs below have something
  # to prove was left alone: a sleep read that stamped the measurement poll's resume point
  # would be #554 and #557 again, and the only way to see it is to have a value there first.
  def connect(account_id, expires_in: 10_800, sleep_read_at: nil, synced_at: Time.now - 86_400)
    Tectonic::WithingsConnection.store(account_id,
                                       { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
                                         'expires_in' => expires_in, 'userid' => '9001' })
    DB[:account_withings].where(account_id:)
                         .update(sleep_read_at:, synced_at:,
                                 measures_read_back_to: synced_at - Tectonic::WithingsMeasures::BACKFILL)
  end

  # One night as Withings sends it: the two ends of the recorded night at the top level, where
  # they arrive whether anybody asked for them or not, and the sleep itself under `data`, where
  # it arrives only because `data_fields` named it.
  #
  # 22_200 seconds is 6h10m, which is the number the arithmetic below is checked against.
  def a_night(id: 7001, from: nil, to: nil, slept: 22_200)
    to ||= Time.now - 3600
    from ||= to - 27_000
    data = slept.nil? ? {} : { 'total_sleep_time' => slept }
    { 'id' => id, 'startdate' => from.to_i, 'enddate' => to.to_i,
      'timezone' => 'Europe/London', 'model' => 16, 'data' => data }
  end

  def page(nights, more: 0, offset: nil)
    { 'series' => nights, 'more' => more, 'offset' => offset }
  end

  # Withings, answering with the pages it is given in order and leaving behind how it was
  # asked. A nil among them is Withings not answering at all, which is every one of its
  # failure modes folded together -- a dead grant and status 601 alike. See Withings.answered.
  def answering(*pages, &)
    @asked = []
    responder = lambda do |path, **query|
      @asked << query.merge(path:)
      pages[@asked.length - 1]
    end
    Tectonic::Withings.stub(:post, responder, &)
  end

  def rows(account_id) = DB[:health_metrics].where(account_id:).order(:metric).all

  def row(account_id, metric) = DB[:health_metrics].where(account_id:, metric:).first

  def connection(account_id) = DB[:account_withings].where(account_id:).first

  def slept_hours = Tectonic::WithingsSleep::SLEPT
  def window_hours = Tectonic::WithingsSleep::WINDOW
end

# The arithmetic, and which end of the night the row is filed at. A night is a span and
# `health_metrics.measured_at` is an instant, which #579 names as the design question this
# piece had to answer; these are the assertions that pin the answer.
describe 'what a night arrives as and what it becomes' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
    @woke = (Time.now - 3600).round
  end

  # Seconds are the API's encoding of a duration, not a unit anybody's watch reports in.
  # 22_200 seconds is 6h10m, and 6.167 is that in the three decimal places the column carries.
  it 'reads the length in hours rather than the seconds it arrives as' do
    answering(page([a_night(to: @woke)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal BigDecimal('6.167'), row(@account_id, slept_hours)[:value]
    assert_equal 'h', row(@account_id, slept_hours)[:unit]
  end

  # The instant-versus-span answer. The near end of a night, relative to the session it is
  # read against, is the waking end -- so that is where the row is filed.
  it 'files the night at the moment the lifter woke rather than when they went to bed' do
    answering(page([a_night(to: @woke)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal @woke, row(@account_id, slept_hours)[:measured_at].to_time.round
  end

  # And the far end is not lost by filing at an instant, because it is a duration and a
  # duration is a measurement: 27_000 seconds is 7h30m of recorded night, of which 6h10m was
  # sleep. Bed time is the wake time less the window.
  it 'records the window the night was recorded over beside the sleep in it' do
    answering(page([a_night(to: @woke)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal BigDecimal('7.5'), row(@account_id, window_hours)[:value]
  end

  it 'gives both rows the one instant, so they read as one night' do
    answering(page([a_night(to: @woke)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal([@woke, @woke], rows(@account_id).map { |found| found[:measured_at].to_time.round })
  end
end

# The failure mode #579 spends its length on, and the two refusals that follow from it: an
# absent field is indistinguishable from an instrument that recorded nothing, and the one
# thing neither of them means is that the lifter did not sleep.
describe 'a night that did not arrive whole' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
    @woke = (Time.now - 3600).round
  end

  it 'writes no length at all where Withings sent none, rather than a zero' do
    answering(page([a_night(to: @woke, slept: nil)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_nil row(@account_id, slept_hours)
  end

  it 'still records the window on a night whose length was not sent' do
    answering(page([a_night(to: @woke, slept: nil)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal BigDecimal('7.5'), row(@account_id, window_hours)[:value]
  end

  # Without the summary's own id there is nothing to make a second read of the same week a
  # no-op, and two rows for one night is a trend drawn twice.
  it 'skips a night with no id rather than storing one it could not store twice safely' do
    answering(page([a_night(id: nil, to: @woke)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_empty rows(@account_id)
  end
end

# The question a lifter actually asks -- "did I sleep badly before that session" -- is a query,
# and the row has to be reachable from what the session already knows about itself.
describe 'the night before a session' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'is found from the session own start, which is what filing at the wake time buys' do
    session_start = Time.now - 3600
    last_night = session_start - 1800
    the_night_before = session_start - (26 * 3600)
    answering(page([a_night(id: 1, to: the_night_before, slept: 18_000),
                    a_night(id: 2, to: last_night, slept: 22_200)])) do
      Tectonic::WithingsSleep.fetch(@account_id)
    end

    found = DB[:health_metrics].where(account_id: @account_id, metric: slept_hours)
                               .where { measured_at < session_start }
                               .order(Sequel.desc(:measured_at)).first

    assert_equal BigDecimal('6.167'), found[:value]
  end
end

# The request itself. Every one of these is a parameter Withings will not tell you about by
# failing: the wrong path is refused, and the missing opt-in comes back as a night with an
# empty `data` and no error at all.
describe 'what a sleep read asks Withings for' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
    answering(page([])) { Tectonic::WithingsSleep.fetch(@account_id) }
    @query = @asked.first
  end

  # `getmeas` answers on /measure and the sleep service answers on /v2/sleep. Each refuses the
  # other's path, and the refusal arrives as an ordinary 200 with a non-zero status.
  it 'asks the sleep service rather than either measure service' do
    assert_equal '/v2/sleep', @query[:path]
    assert_equal 'getsummary', @query[:action]
  end

  # The trap `WORKOUT_FIELDS` already documents, in its other place: every field under `data`
  # is an opt-in, so a request without this comes back with nights in it and nothing in them.
  it 'names the field it wants, because the answer carries none unasked' do
    assert_includes @query[:data_fields].split(','), 'total_sleep_time'
  end

  # Withings' reference: "A single call can span up to 7 days maximum."
  it 'asks for no more days than one call may span' do
    from = Date.parse(@query[:startdateymd])
    to = Date.parse(@query[:enddateymd])

    assert_operator((to - from).to_i, :<=, 6)
  end

  it 'sends the token as a bearer credential rather than a form field' do
    assert_equal 'access-1', @query[:token]
  end
end

# The unique index on [source, external_id] is what makes re-reading a week free of
# consequence, and re-reading a week is the whole reason the window is as wide as it is.
describe 'reading the same week twice' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'stores each night once' do
    2.times do
      answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }
    end

    assert_equal 2, rows(@account_id).length
  end

  it 'counts only what was new, so a second read reports nothing arrived' do
    answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }
    second = answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal 0, second.stored
  end

  # A sleep summary id and a measure group id are different id spaces from one provider, and
  # the unique index is on [source, external_id] across the whole table.
  it 'cannot collide with a weigh-in that happens to carry the same id' do
    DB[:health_metrics].insert(account_id: @account_id, metric: 'weight', value: 81.4, unit: 'kg',
                               measured_at: Time.now, source: Tectonic::WithingsSleep::SOURCE,
                               external_id: "#{@account_id}:7001:1")
    answering(page([a_night(id: 7001)])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal 2, DB[:health_metrics].where(account_id: @account_id, metric: slept_hours).count + 1
  end
end

# The honesty contract the rest of the integration keeps: a failed read may never render as
# "you did not sleep". `Withings.post` folds a throttle into the same nil as a dead grant, so
# the outcome is on the struct rather than left to be inferred from a count of zero.
describe 'what a sleep read says it did' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'says stored when the whole window arrived' do
    fetch = answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal :stored, fetch.outcome
    assert_equal 2, fetch.stored
  end

  it 'says unreachable, rather than that nobody slept, when Withings did not answer' do
    fetch = answering(nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal :unreachable, fetch.outcome
    assert_predicate fetch, :failed?
  end

  # A first page that says there is more and then nothing, which is what status 601 looks like
  # by the time it has been through Withings.answered.
  it 'says incomplete when a later page went missing' do
    fetch = answering(page([a_night], more: 1, offset: 5), nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal :incomplete, fetch.outcome
    assert_predicate fetch, :failed?
  end

  # The rows that did arrive are real and are kept, exactly as a truncated measurement read
  # keeps its own.
  it 'keeps what arrived before the page that did not' do
    answering(page([a_night], more: 1, offset: 5), nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal 2, rows(@account_id).length
  end
end

# The two outcomes that are not about a request at all: one grant that is gone, and one account
# that never had one. They are told apart from every other failure because they are the only
# two this app can be certain of -- everything else Withings does arrives as the same nil.
describe 'a sleep read with no usable connection behind it' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  # The one failure that really does mean somebody has to do something, and the only one this
  # can tell from the rest: a refresh that came back empty.
  it 'says revoked only when the refresh failed' do
    connect(@account_id, expires_in: -60)
    fetch = Tectonic::Withings.stub(:refresh, nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal :revoked, fetch.outcome
  end

  it 'says absent where nothing is connected' do
    assert_equal :absent, Tectonic::WithingsSleep.fetch(an_account).outcome
  end
end

# Withings ask not to be polled more than once every ten minutes per user, and an assistant
# answering one question makes several tool calls. The floor is what keeps a conversation of a
# dozen of them to one HTTP call.
describe 'when a sleep read asks at all' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'does not ask again inside the floor' do
    connect(@account_id, sleep_read_at: Time.now - 60)
    fetch = answering(page([a_night])) { Tectonic::WithingsSleep.freshen(@account_id) }

    assert_equal :fresh, fetch.outcome
    assert_empty @asked
  end

  it 'asks again once the floor has passed' do
    connect(@account_id, sleep_read_at: Time.now - (60 * 60))
    answering(page([a_night])) { Tectonic::WithingsSleep.freshen(@account_id) }

    refute_empty @asked
  end
end

# A week with nothing in it is an answer, and it is the answer that looks most like a failure.
# Telling the two apart is the whole reason the outcome is on the struct rather than inferred
# from a count of zero.
describe 'a week with no nights in it' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'says stored rather than anything that reads as a refusal' do
    fetch = answering(page([])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal :stored, fetch.outcome
    refute_predicate fetch, :failed?
  end

  it 'is still a week that has been read' do
    answering(page([])) { Tectonic::WithingsSleep.fetch(@account_id) }

    refute_nil connection(@account_id)[:sleep_read_at]
  end
end

# The hard constraint. #554 and #557 are both bugs of one shape -- two different fetches
# sharing one watermark -- and a sleep read stamping `synced_at` would tell the measurement
# poller it had already read a window of weigh-ins nobody has ever fetched.
describe 'the watermark a sleep read keeps' do
  include NightsSleep

  before do
    @account_id = an_account
    @synced_at = (Time.now - 86_400).round
    connect(@account_id, synced_at: @synced_at)
  end

  it 'moves its own' do
    answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }

    refute_nil connection(@account_id)[:sleep_read_at]
  end

  it 'never moves the measurement poll resume point' do
    answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal @synced_at, connection(@account_id)[:synced_at].to_time.round
  end

  it 'never moves how far back the measurement history has been read' do
    before_read = connection(@account_id)[:measures_read_back_to]
    answering(page([a_night])) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_equal before_read, connection(@account_id)[:measures_read_back_to]
  end
end

# A read that stopped has not read everything up to anywhere, and saying it has trades a slow
# loop for nights that go silently missing -- which is the failure `:incomplete` exists to
# report rather than hide.
describe 'the watermark a sleep read that did not finish keeps' do
  include NightsSleep

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'leaves its own watermark alone when the read did not finish' do
    answering(page([a_night], more: 1, offset: 5), nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_nil connection(@account_id)[:sleep_read_at]
  end

  it 'leaves its own watermark alone when Withings did not answer at all' do
    answering(nil) { Tectonic::WithingsSleep.fetch(@account_id) }

    assert_nil connection(@account_id)[:sleep_read_at]
  end
end

# 041 made `metric` free text so that a new reading is a line in a hash rather than a
# migration; `BodyReadings::KNOWN` is the list a model is told to try. A name in that list
# that nothing writes is a name every caller gets silence from.
describe 'the metric names a reader is offered' do
  it 'names the ones a sleep read actually writes' do
    assert_includes Tectonic::BodyReadings::KNOWN, Tectonic::WithingsSleep::SLEPT
    assert_includes Tectonic::BodyReadings::KNOWN, Tectonic::WithingsSleep::WINDOW
  end

  it 'no longer offers a name nothing has ever written' do
    refute_includes Tectonic::BodyReadings::KNOWN, 'sleep_minutes'
    refute_includes Tectonic::BodyReadings::KNOWN, 'resting_hr'
  end

  # The other half of the same correction: #581 wrote `standing_hr` and declined to call it
  # `resting_hr`, and the list went on advertising the name with no rows behind it instead of
  # the one with rows.
  it 'offers the name the measurement read actually writes' do
    assert_includes Tectonic::BodyReadings::KNOWN, 'standing_hr'
    assert_includes Tectonic::BodyReadings::KNOWN, Tectonic::WithingsMeasures::METRICS.fetch(11).first
  end
end

# The join #533 exists to prevent the absence of: a fetch wired to nothing is a table that
# stays empty while every other part of the app reports the connection as live.
describe 'a tool call asking about sleep' do
  include Rack::Test::Methods
  include ScaleReadings
  include NightsSleep

  before do
    @token = mint(scopes: ['read'])
    connect(@token.account_id)
  end

  def ask(metric) = call_tool('health_readings', raw: @token.raw, arguments: { metric: })

  it 'reads the watch before it reads the table' do
    answering(page([a_night])) { ask(slept_hours) }

    assert_equal 6.167, structured['instruments'].fetch(0)['latest']['value']
  end

  # One request per tool call, never two. A question about bodyweight cannot be answered
  # differently by anything the watch says.
  it 'does not read the watch when the question is about bodyweight' do
    answering(page([a_night])) { ask('weight') }

    refute_equal '/v2/sleep', @asked.first[:path]
  end
end

# What the answer says about the read it just made. A tool that fetched and then said nothing
# about what came back would pass every assertion above and still be the silent lie #533 was
# opened over.
describe 'what a tool call about sleep says of the read behind it' do
  include Rack::Test::Methods
  include ScaleReadings
  include NightsSleep

  before do
    @token = mint(scopes: ['read'])
    connect(@token.account_id)
  end

  def ask(metric) = call_tool('health_readings', raw: @token.raw, arguments: { metric: })

  it 'says the watch was just read rather than saying nothing about it' do
    answering(page([a_night])) { ask(slept_hours) }

    assert_includes prose, 'Read from the watch just now'
  end

  it 'says when it last read the watch rather than claiming to have just read it' do
    connect(@token.account_id, sleep_read_at: Time.now - 60)
    answering(page([a_night])) { ask(slept_hours) }

    assert_includes prose, 'Last read from the watch at'
  end

  # The lie this whole apparatus exists to prevent, in its sleep-shaped form.
  it 'never renders a read that failed as a night with no sleep in it' do
    answering(nil) { ask(slept_hours) }

    assert_includes prose, 'could not be reached'
    assert_equal true, structured.dig('freshness', 'readings_may_be_missing')
  end
end

