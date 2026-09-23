# frozen_string_literal: true

require_relative 'spec_helper'
# The two files whose helpers this one is the join of, exactly as reading_the_scale_spec
# requires mcp_spec for the same reason: the fixtures for a stubbed Withings live in one and
# the fixtures for calling a tool over HTTP live in the other, and #533 is the ticket where
# those two halves finally meet. Both requires are idempotent.
require_relative 'fetching_from_the_scale_spec' # FetchingFromTheScale: connect, answering, page, a_weigh_in
require_relative 'reading_the_scale_spec' # ScaleReadings: prose, structured, and mcp_spec's mint/call_tool
require_relative '../lib/tectonic/withings_measures'

# Reading the scale when somebody reads the numbers. #533.
#
# Nothing here talks to Withings, on the same grounds as the two files above: every call is
# stubbed at `Withings.post`, which is the one seam every provider failure is folded through,
# so a rate limit and a dead socket are expressed here the way the app actually meets them --
# as nil. A spec that reached the real API would be testing somebody else's service and would
# fail on a runner with no credentials.
#
# What is asserted is the half #533 is actually about: not that the call happens, which is one
# line, but what each tool says about what came back. A caller that fetched and then ignored
# the outcome would pass every test in reading_the_scale_spec.
module CurrentScale
  include FetchingFromTheScale
  include ScaleReadings

  THREE = %w[health_readings bodyweight_trend body_composition].freeze

  # A token whose account has a Withings connection last read a day ago -- stale, so a read
  # through any of the three tools is due a fetch.
  def a_connected_lifter(synced_at: Time.now - 86_400)
    @token = mint(scopes: ['read'])
    connect(@token.account_id, synced_at:)
    @token
  end

  # A connection whose access token is spent and whose refresh will fail, which is the only
  # thing in this system that can tell a withdrawn grant from a provider having a bad
  # afternoon: a read has to refresh first, and it is the refresh that comes back empty.
  def a_lifter_whose_grant_is_gone
    @token = mint(scopes: ['read'])
    connect(@token.account_id, expires_in: -60, synced_at: Time.now - 86_400)
    @token
  end

  def revoked(&) = Tectonic::Withings.stub(:refresh, nil, &)

  # A first page that says there is more, and then nothing -- which is what status 601 looks
  # like by the time it has been through Withings.answered.
  def throttled(&) = answering(page([a_weigh_in], more: 1, offset: 5), nil, &)

  # Each tool asked for whatever it insists on, so one assertion can be made of all three.
  def ask(name, arguments = {})
    call_tool(name, raw: @token.raw, arguments: arguments.merge(name == 'health_readings' ? { metric: 'weight' } : {}))
  end

  def freshness = structured['freshness']

  def failed? = tool_result['isError']
end

# The bug itself: a lifter connects a scale, the settings page reports the connection live,
# and the table stays empty because nothing ever asked Withings for anything.
describe 'a tool call on an account whose scale has not been read' do
  include Rack::Test::Methods
  include CurrentScale

  before { a_connected_lifter }

  it 'reads the scale before it reads the table' do
    answering(page([a_weigh_in])) { ask('health_readings') }

    assert_equal 81.448, only_instrument['latest']['value']
  end

  it 'says the numbers were just read, and how many were new' do
    answering(page([a_weigh_in])) { ask('health_readings') }

    assert_equal 'stored', freshness['outcome']
    assert_equal 2, freshness['new_readings']
  end

  # All three, because the fetch belongs to reading rather than to any one of the tools, and
  # a lifter who happens to ask for their body composition first should not get a stale one.
  # The connection is staled again between them because the first call's success moves
  # `synced_at` to now, which is the floor working and would otherwise read as the second
  # tool declining to fetch.
  it 'is done by each of the three reading tools' do
    CurrentScale::THREE.each do |name|
      connect(@token.account_id, synced_at: Time.now - 86_400)
      answering(page([a_weigh_in])) { ask(name) }

      refute_empty @asked, "#{name} read the table without reading the scale"
    end
  end
end

# Withings' own guidance is not to ask for one user's measures more than once every ten
# minutes, and an assistant answering one question makes several tool calls.
describe 'a second tool call straight after the first' do
  include Rack::Test::Methods
  include CurrentScale

  before { a_connected_lifter(synced_at: Time.now - 60) }

  it 'does not ask Withings again' do
    answering(page([a_weigh_in])) { ask('bodyweight_trend') }

    assert_empty @asked
  end

  it 'says when the numbers were last read rather than claiming to have just read them' do
    answering(page([a_weigh_in])) { ask('bodyweight_trend') }

    assert_equal 'fresh', freshness['outcome']
    assert_includes prose, 'Last read from the scale at'
  end
end

# The failure that means something has to be done. A grant can be withdrawn from Withings'
# own app, and the only symptom is readings quietly stopping -- which a window reported over
# three weeks that ends in the first of them renders as a bodyweight that has been flat.
describe 'a connection whose grant has been withdrawn' do
  include Rack::Test::Methods
  include CurrentScale

  before do
    a_lifter_whose_grant_is_gone
    daily(@token.account_id, [81.2, 81.5, 81.1, 81.8, 81.4])
  end

  it 'tells each of the three tools to say the connection needs renewing' do
    CurrentScale::THREE.each do |name|
      revoked { ask(name) }

      assert_includes prose, 'needs renewing', "#{name} reported a dead connection as though it were live"
    end
  end

  it 'says so before the numbers rather than after them' do
    revoked { ask('bodyweight_trend') }

    assert_includes prose.lines.first, 'needs renewing'
  end

  it 'marks the readings as possibly not the whole story' do
    revoked { ask('health_readings') }

    assert freshness['readings_may_be_missing']
    assert_equal 'revoked', freshness['outcome']
  end
end

# A withdrawn grant is a reason to say where the numbers stop, and not a reason to refuse a
# lifter the fortnight they have already weighed.
describe 'what a withdrawn grant does not stop' do
  include Rack::Test::Methods
  include CurrentScale

  before { a_lifter_whose_grant_is_gone }

  it 'still reports what was already stored' do
    daily(@token.account_id, [81.2, 81.5, 81.1, 81.8, 81.4])
    revoked { ask('bodyweight_trend') }

    assert_equal 5, only_instrument['readings']
  end

  # The empty answer is the one that matters most: "no readings" is a true sentence about a
  # lifter who stopped weighing themselves and about a connection that stopped delivering,
  # and only one of the two is something to do anything about.
  it 'does not let an empty window read as a lifter who has not weighed in' do
    revoked { ask('health_readings') }

    assert_empty instruments
    assert_includes prose, 'needs renewing'
  end
end

# The case worth the most care. Withings signals rate limiting as status 601 inside an
# ordinary HTTP 200, so a throttled fetch stops mid-window: the rows that arrived are real,
# and the window has a hole in it that none of the numbers show.
describe 'a fetch that stopped partway through the window' do
  include Rack::Test::Methods
  include CurrentScale

  before { a_connected_lifter }

  it 'warns every one of the three that the window may have a hole in it' do
    CurrentScale::THREE.each do |name|
      throttled { ask(name) }

      assert_includes prose, 'hole in it', "#{name} reported a partial window as a whole one"
    end
  end

  it 'leads with the warning, where a client that renders one line still shows it' do
    throttled { ask('bodyweight_trend') }

    assert_includes prose.lines.first, 'stopped answering partway'
  end

  it 'keeps what did arrive rather than throwing the page away' do
    throttled { ask('health_readings') }

    assert_equal 'incomplete', freshness['outcome']
    assert_equal 1, only_instrument['readings']
  end
end

# The warning is not one sentence said three times. What a hole in the window does to an
# answer depends on the answer, and a tool that cannot say which of its own figures the gap
# threatens has not really said anything.
describe 'what each tool says a hole in the window would do to it' do
  include Rack::Test::Methods
  include CurrentScale

  before { a_connected_lifter }

  # The one #533 asks for by name: a rolling mean over a window with a gap in it looks
  # exactly like one over a whole window and is a different number.
  it 'names the rolling mean, in the tool that computes one' do
    throttled { ask('bodyweight_trend') }

    assert_includes prose, 'rolling mean over a window with a gap'
  end

  it 'names the weigh-in and its band, in the tool that reports one' do
    throttled { ask('body_composition') }

    assert_includes prose, 'may not be the most recent one taken'
  end

  it 'names the count and the range, in the tool that aggregates them' do
    throttled { ask('health_readings') }

    assert_includes prose, 'describe a smaller window than the one asked for'
  end
end

# A fetch must never make a read fail: Withings having a bad afternoon degrades a tool to
# "here is what I have", and never to an error.
describe 'a fetch that could not reach Withings at all' do
  include Rack::Test::Methods
  include CurrentScale

  before do
    a_connected_lifter
    daily(@token.account_id, [81.2, 81.5, 81.1])
  end

  it 'still answers, with what was already stored' do
    answering(nil) { ask('health_readings') }

    refute failed?
    assert_equal 3, only_instrument['readings']
  end

  it 'declines to call the stored history current' do
    answering(nil) { ask('health_readings') }

    assert_equal 'unreachable', freshness['outcome']
    assert_includes prose, 'could not be reached just now'
  end

  # The rescue of last resort. `freshen` is careful and `Withings.post` is more careful
  # still, so an exception here is one neither foresaw -- and the one thing it may not do is
  # turn a lifter's question into "the tool failed unexpectedly".
  it 'survives a fetch that raises rather than returning nil' do
    Tectonic::WithingsMeasures.stub(:freshen, ->(*) { raise 'Withings is having an afternoon' }) do
      ask('health_readings')
    end

    refute failed?
    assert_equal 3, only_instrument['readings']
    assert_equal 'unreachable', freshness['outcome']
  end
end

# Most accounts have no scale at all, and nothing about that is a failure. It is still worth
# one clause: a model reading "no readings" cannot otherwise tell a scale that has not synced
# from an account that never had one, and those want opposite next moves.
describe 'an account with no scale connected' do
  include Rack::Test::Methods
  include CurrentScale

  before do
    @token = mint(scopes: ['read'])
    daily(@token.account_id, [81.2, 81.5], source: 'manual')
  end

  it 'calls nobody' do
    answering(page([a_weigh_in])) { ask('health_readings') }

    assert_empty @asked
  end

  it 'reports the readings it has and says none of them came from a scale' do
    ask('health_readings')

    assert_equal 2, only_instrument['readings']
    assert_equal 'absent', freshness['outcome']
    assert_includes prose, 'No scale is connected'
  end

  it 'does not describe them as possibly missing, because nothing is' do
    ask('health_readings')

    refute freshness['readings_may_be_missing']
  end
end

