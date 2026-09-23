# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/withings'
require_relative '../lib/tectonic/withings_connection'
require_relative '../lib/tectonic/withings_measures'
require 'securerandom'
require 'bigdecimal'

# Reading what the scale recorded. #518.
#
# Nothing here talks to Withings, for the same reason `connecting_a_scale_spec` does not: you
# cannot test somebody else's API, only this app's handling of what it sends back. What is
# asserted is the handful of things that are genuinely easy to get wrong -- the unit
# arithmetic, the window, the idempotence the unique index provides, and the difference
# between a fetch that failed and a fortnight with no weigh-ins in it.
#
# The stub sits on `Withings.post` rather than on `Withings.measures`, one layer lower than is
# strictly needed, so that the parameters the call is actually built from -- the action, the
# category, the bearer token -- are asserted rather than assumed. Stubbing `measures` would
# have tested this file's idea of the request instead of the app's.
module FetchingFromTheScale
  # An account with no web request behind it. Nothing in this file is a route, so signing one
  # in would only be a slower way to get an id.
  def an_account
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: 'not-a-real-hash')
  end

  # A connection that has been read is one that has been read *back* to somewhere as well, so
  # the two watermarks are set together: every row a fetch writes carries both, and 046 gave
  # both to the connections that predate it. Setting only the first would describe a row this
  # app no longer produces -- one whose year is unaccounted for -- and would quietly turn every
  # spec below into a spec about walking a year again.
  def connect(account_id, expires_in: 10_800, synced_at: nil)
    Tectonic::WithingsConnection.store(account_id,
                                       { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
                                         'expires_in' => expires_in, 'userid' => '9001' })
    return unless synced_at

    DB[:account_withings].where(account_id:)
                         .update(synced_at:, measures_read_back_to: synced_at - Tectonic::WithingsMeasures::BACKFILL)
  end

  # 81448 at unit -3 is 81.448 kg, which is the arithmetic the whole ingest turns on.
  def weight(value: 81_448, unit: -3) = { 'type' => 1, 'value' => value, 'unit' => unit }
  def fat_ratio(value: 27_900, unit: -3) = { 'type' => 6, 'value' => value, 'unit' => unit }

  def a_weigh_in(grpid: 4001, at: Time.now - 3600, measures: nil, attrib: 0)
    { 'grpid' => grpid, 'date' => at.to_i, 'attrib' => attrib, 'category' => 1,
      'measures' => measures || [weight, fat_ratio] }
  end

  def page(groups, more: 0, offset: nil)
    { 'measuregrps' => groups, 'more' => more, 'offset' => offset }
  end

  # Withings, answering with the pages it is given in order, and leaving behind how it was
  # asked. A nil among the pages is Withings not answering at all, which is every one of its
  # failure modes folded together -- see Withings.answered.
  def answering(*pages, &)
    @asked = []
    responder = lambda do |_path, **query|
      @asked << query
      pages[@asked.length - 1]
    end
    Tectonic::Withings.stub(:post, responder, &)
  end

  # The pages given, and then empty ones for however many more requests a whole read makes. A
  # read reaching back a year is several requests rather than one (#557), and a spec about what
  # a read concluded should not also be a spec about how many of them there are.
  def a_whole_read(*given, &) = answering(*given, *Array.new(8) { page([]) }, &)

  # What each request asked for: how wide a window, and how far back it reached.
  def widths = @asked.map { |query| query[:enddate] - query[:startdate] }
  def reaches = @asked.map { |query| Time.at(query[:startdate]) }

  def readings(account_id) = DB[:health_metrics].where(account_id:).order(:metric).all
  def synced_at(account_id) = DB[:account_withings].where(account_id:).get(:synced_at)
end

# The arithmetic, which #518 calls the quirk that will bite: a measure is a value and a unit
# and the number is value * 10 ** unit. Taking the value at face value stores a bodyweight of
# eighty-one thousand, which nothing refuses and a chart discovers.
describe 'what a measure actually says' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'reads the exponent rather than the raw value' do
    answering(page([a_weigh_in(measures: [weight])])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal BigDecimal('81.448'), readings(@account_id).first[:value]
  end

  # A Float would have made this 81.44800000000001 and Postgres would have rounded it back,
  # which is right by accident and only while three places happens to be enough.
  it 'is exact rather than nearly right' do
    answering(page([a_weigh_in(measures: [weight(value: 100_125, unit: -3)])])) do
      Tectonic::WithingsMeasures.fetch(@account_id)
    end

    assert_equal BigDecimal('100.125'), readings(@account_id).first[:value]
  end

  # Stored in the unit given. A kilogram converted on the way in is a number the lifter never
  # saw on their own scale.
  it 'keeps the unit Withings gave rather than converting it' do
    answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal(['%', 'kg'], readings(@account_id).map { |row| row[:unit] })
  end

  it 'names each number rather than storing it under a type code' do
    answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal(%w[fat_ratio weight], readings(@account_id).map { |row| row[:metric] })
  end
end

# What becomes a row and what does not, and when the row says it happened.
describe 'which of a weigh-in is kept' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  # A type this app has no name for is skipped rather than stored as "91", which would be a
  # row nothing ever reads on purpose.
  it 'skips a measure it has no name for' do
    strange = { 'type' => 91, 'value' => 5, 'unit' => 0 }
    answering(page([a_weigh_in(measures: [weight, strange])])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 1, readings(@account_id).length
  end

  # The date on the group, not the moment the row appeared. This is the entire reason
  # measured_at is a column of its own.
  it 'records when the reading was taken rather than when it was fetched' do
    taken = Time.now - (3 * 24 * 60 * 60)
    answering(page([a_weigh_in(at: taken)])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_in_delta taken, readings(@account_id).first[:measured_at], 1
  end
end

# Re-reading a window the app has already read is deliberate, because health data arrives
# late. It is only safe because of the unique index, so this asserts the index is actually
# being relied on rather than merely present.
describe 'reading a window twice' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'stores each reading once however often it is fetched' do
    3.times { answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) } }

    assert_equal 2, readings(@account_id).length
  end

  # And says so: the count is what this fetch added, not what the window held, so a caller
  # can tell "nothing new" from "two new readings".
  it 'counts only what was new' do
    answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) }
    again = answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 0, again.stored
  end

  # The unique index is on [source, external_id] across the whole table rather than per
  # account, so two lifters whose scales hand out the same group id must not collide. They
  # would, silently, with a bare grpid as the external id.
  it 'keeps two accounts apart when the scales hand out the same group id' do
    other = an_account
    connect(other)
    [@account_id, other].each do |id|
      answering(page([a_weigh_in(grpid: 7777)])) { Tectonic::WithingsMeasures.fetch(id) }
    end

    assert_equal 2, readings(@account_id).length
    assert_equal 2, readings(other).length
  end
end

# How the call is built, which is the half of this that cannot be seen from the stored rows.
describe 'the window a fetch asks for' do
  include FetchingFromTheScale

  before { @account_id = an_account }

  # A year, so somebody connecting today has a trend rather than a point -- and bounded,
  # rather than all of it.
  #
  # Across the requests rather than in the first of them, since #557: the year is asked for a
  # piece at a time so that a read refused partway has something to show for the pieces that
  # arrived. What the lifter gets is unchanged, which is what this asserts.
  it 'reaches a year back on the first fetch' do
    connect(@account_id)
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_in_delta Time.now - Tectonic::WithingsMeasures::BACKFILL, reaches.min, 60
  end

  # And a week behind the last success afterwards, because a forward-only window loses exactly
  # the late arrivals that measured_at exists to record.
  it 'reaches a week behind the last success afterwards' do
    connect(@account_id, synced_at: Time.now - 3600)
    answering(page([])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_in_delta Time.now - 3600 - Tectonic::WithingsMeasures::OVERLAP,
                    Time.at(@asked.first[:startdate]), 60
  end

  # Real readings, not the goals the same endpoint returns under category 2 -- which would
  # file a target bodyweight as though somebody had stood on a scale and weighed it.
  it 'asks for readings rather than for goals' do
    connect(@account_id)
    answering(page([])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 1, @asked.first[:category]
  end
end

# Withings' own peculiarities, which are not guessable and which fail quietly when guessed.
describe 'how Withings has to be asked' do
  include FetchingFromTheScale

  before { @account_id = an_account }

  # Every Withings call is a POST carrying an action, including the ones any other API would
  # make a GET.
  it 'names the method in the body, the way Withings wants' do
    connect(@account_id)
    answering(page([])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 'getmeas', @asked.first[:action]
  end

  # In the Authorization header rather than as a form field, which is the shape Withings
  # retired and which fails as "invalid token" -- indistinguishable from a revoked grant.
  it 'carries the access token' do
    connect(@account_id)
    answering(page([])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 'access-1', @asked.first[:token]
  end
end

# Withings pages a wide window, and a fetch that read only the first page would keep the
# newest readings and drop the older end of the window without saying anything.
describe 'a window wider than one page' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  # The second page is asked for with the offset the first handed back and within the same
  # window, which is what tells a resumed page from the next piece of the year.
  it 'follows more and offset to the end' do
    a_whole_read(page([a_weigh_in(grpid: 1)], more: 1, offset: 88), page([a_weigh_in(grpid: 2)])) do
      Tectonic::WithingsMeasures.fetch(@account_id)
    end

    assert_equal 88, @asked[1][:offset]
    assert_equal @asked[0][:startdate], @asked[1][:startdate]
    assert_equal 4, readings(@account_id).length
  end

  # Documented as a number and observed as a boolean, so both are read. Four readings is the
  # assertion, because the second page was only ever asked for to be stored.
  it 'reads more whether it is a number or a boolean' do
    a_whole_read(page([a_weigh_in(grpid: 1)], more: true), page([a_weigh_in(grpid: 2)])) do
      Tectonic::WithingsMeasures.fetch(@account_id)
    end

    assert_equal 4, readings(@account_id).length
  end
end

# The distinction the whole module turns on. Every Withings failure -- a dead token, a bad
# secret, and status 601 "too many request" -- arrives as the same nil, so a fetch that came
# back with nothing cannot say why and must not be read as a lifter who has not weighed in.
describe 'a fetch that did not come back' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'says it could not read rather than reporting an empty window' do
    result = answering(nil) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal :unreachable, result.outcome
    assert_predicate result, :failed?
  end

  # An empty window is the other side of it, and is not a failure: a fortnight with no
  # weigh-ins in it is a true answer.
  it 'tells an empty window apart from a failed one' do
    result = a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal :stored, result.outcome
    refute_predicate result, :failed?
  end

  # The resume point must not move past readings nobody ever saw.
  it 'leaves the resume point where it was' do
    answering(nil) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_nil synced_at(@account_id)
  end
end

# Rate limiting is the case that makes this matter: a wide window is several calls, and the
# one that gets refused is as likely to be the third as the first.
describe 'a fetch that stopped halfway' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  # A page that fails halfway still keeps what arrived -- the rows are idempotent and the
  # window will be asked for again -- but it may not claim the window was complete.
  it 'keeps a short read without calling it a whole one' do
    result = answering(page([a_weigh_in], more: 1, offset: 5), nil) do
      Tectonic::WithingsMeasures.fetch(@account_id)
    end

    assert_equal :incomplete, result.outcome
    assert_equal 2, readings(@account_id).length
    assert_nil synced_at(@account_id)
  end
end

# The one failure that really does mean the connection needs renewing: a refresh that failed.
# It is distinct from the above precisely because it is the only one that knows.
describe 'a grant that has been revoked' do
  include FetchingFromTheScale

  before { @account_id = an_account }

  it 'says the connection needs renewing rather than retrying' do
    connect(@account_id, expires_in: -60)

    result = Tectonic::Withings.stub(:refresh, nil) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal :revoked, result.outcome
  end

  it 'says nothing is connected when nothing is' do
    assert_equal :absent, Tectonic::WithingsMeasures.fetch(@account_id).outcome
  end
end

# Set on a success, and the column stops being one that is declared and never written.
describe 'when the numbers were last read' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'is recorded after a fetch that finished' do
    answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_in_delta Time.now, synced_at(@account_id), 60
  end
end

# What triggers a fetch, which is #518's open question. Fetch when somebody is about to read,
# and only if the last read is stale: no scheduled job, no second Render service, and nothing
# happening that nobody asked for.
describe 'fetching because somebody is about to read' do
  include FetchingFromTheScale

  before { @account_id = an_account }

  it 'reads again when the last read is old' do
    connect(@account_id, synced_at: Time.now - (24 * 60 * 60))
    result = answering(page([a_weigh_in])) { Tectonic::WithingsMeasures.freshen(@account_id) }

    assert_equal :stored, result.outcome
  end

  # Ten minutes is Withings' own guidance on how often one user's measures may be asked for,
  # so a conversation making a dozen tool calls must make one HTTP call, not a dozen.
  it 'does not call Withings again straight away' do
    connect(@account_id, synced_at: Time.now - 60)
    answering(page([a_weigh_in])) do
      assert_equal :fresh, Tectonic::WithingsMeasures.freshen(@account_id).outcome
    end

    assert_empty @asked
  end

  it 'reads on the first ask, when there has never been one' do
    connect(@account_id)
    result = a_whole_read(page([a_weigh_in])) { Tectonic::WithingsMeasures.freshen(@account_id) }

    assert_equal :stored, result.outcome
  end

  it 'calls nobody for an account that has not connected anything' do
    assert_equal :absent, Tectonic::WithingsMeasures.freshen(@account_id).outcome
  end
end

# A household scale hands out readings Withings itself is not sure belong to this person, and
# this table has nowhere to write "probably". A housemate's bodyweight in a lifter's trend is
# wrong in the way nobody can see.
describe 'a reading that might not be this lifter' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'skips the ones Withings flags as possibly somebody else' do
    answering(page([a_weigh_in(attrib: 1)])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_empty readings(@account_id)
  end

  it 'keeps a reading entered by hand, which is this lifter saying so' do
    answering(page([a_weigh_in(attrib: 2)])) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 2, readings(@account_id).length
  end
end

# How much one request is allowed to ask for. #557.
#
# A first read reaches back a year, and asking for the whole of it at once makes the widest
# and most expensive request this app has -- which is also the one likeliest to be refused
# partway. What a refusal leaves behind is rows and no resume point, because a truncated
# answer says nothing this app may rely on about which end of the window it holds.
describe 'how wide a single request gets' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'never asks for the whole year at once' do
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_operator widths.max, :<, Tectonic::WithingsMeasures::BACKFILL,
                    'one request asked for the entire year'
  end

  # The window itself is unchanged and a first read still reaches a year back, which is
  # asserted where the window is: it is the request that got smaller, not what a lifter gets.
  #
  # And the pieces meet. A year asked for in pieces with a gap between two of them would be a
  # fortnight nobody ever reads, which is worse than the single request it replaced.
  it 'leaves no gap between one request and the next' do
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    @asked.each_cons(2) { |newer, older| assert_equal newer[:startdate], older[:enddate] }
  end
end

# The bug in #557. `synced_at` moves only for a window that arrived whole, so a first read
# refused partway left nothing behind at all: the next read asked for the same year, and the
# request most likely to be throttled was the one retried forever.
describe 'a read Withings cut short' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'does not ask for as much the next time' do
    answering(page([a_weigh_in], more: 1, offset: 5), nil) { Tectonic::WithingsMeasures.fetch(@account_id) }
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_operator widths.max, :<, Tectonic::WithingsMeasures::BACKFILL,
                    'the read after a refused one asked for the whole year again'
  end

  # What the part that did arrive earns: the next read picks up where this one stopped rather
  # than starting again at the near end of the year.
  it 'comes back for the piece Withings refused' do
    answering(page([a_weigh_in]), nil) { Tectonic::WithingsMeasures.fetch(@account_id) }
    refused = @asked.last
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert(@asked.any? do |query|
      (query[:startdate] - refused[:startdate]).abs <= 1 && (query[:enddate] - refused[:enddate]).abs <= 1
    end, 'the next read never came back for the piece that was refused')
  end

  # The two watermarks, and the difference between them. A piece that arrived whole is whole
  # whatever order Withings sent it in, so the readings up to this instant really have been
  # read -- and the window as a whole still has a hole in it, which is what the outcome says
  # and what a reader has to be told.
  it 'calls the window incomplete even where the newest piece of it arrived' do
    result = answering(page([a_weigh_in]), nil) { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal :incomplete, result.outcome
    assert_in_delta Time.now, synced_at(@account_id), 60
  end
end

# A connection nobody has read in months. The window ending now is capped at a step, which
# leaves the months between that cap and the last success asked for by nothing -- and readings
# skipped in silence are worse than readings fetched twice, which is what the whole file is
# arranged around.
describe 'a read of a connection left alone for months' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id, synced_at: Time.now - (200 * 24 * 60 * 60))
  end

  # Across the two reads rather than within either, because which of them covers those months
  # is an implementation's business and whether anything ever does is not.
  it 'asks for the months between the last success and the window it could ask for' do
    windows = []
    2.times do
      a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }
      windows.concat(@asked)
    end
    missed = (Time.now - (150 * 24 * 60 * 60)).to_i

    assert(windows.any? { |query| missed.between?(query[:startdate], query[:enddate]) },
           'the months between the last read and this one were never asked for')
  end
end

# The cheap steady state the fifteen-minute floor was designed around, and the thing #557 is
# about an account never reaching: one narrow request, a week behind the last success.
describe 'a read once the year has been read' do
  include FetchingFromTheScale

  before do
    @account_id = an_account
    connect(@account_id)
  end

  it 'asks for a week and nothing else' do
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }
    a_whole_read { Tectonic::WithingsMeasures.fetch(@account_id) }

    assert_equal 1, @asked.length
    assert_in_delta Tectonic::WithingsMeasures::OVERLAP, widths.first, 60
  end
end

