# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/error_reporting'

# How long things take, as against what broke. #388.
#
# Sentry has two halves and only the error half was on, which left three numbers resting on
# reasoning nobody had checked against a measurement: the twenty-second request timeout, the
# connection pool, and an MCP endpoint whose own comment admits nobody has watched its request
# pattern.
#
# Most of this file is about the half of the work #388 did not ask for. That issue recommends
# the Sequel integration in one line -- "worth enabling alongside" -- and enabling it as
# written would have shipped people's email addresses to a third party, because Sequel inlines
# literals into its SQL rather than using bound parameters.
module Tracing
  # The shapes that actually come out of this app's own query builder, rather than invented
  # SQL. The first is the one that matters: it is what `DB[:accounts].where(email:)` produces,
  # and it is how somebody's address would have reached a monitoring vendor.
  STATEMENTS = {
    'an email address' => [
      %{SELECT * FROM "accounts" WHERE ("email" = 'someone@example.com')},
      %{SELECT * FROM "accounts" WHERE ("email" = '?')}
    ],
    'a movement somebody named' => [
      %{SELECT "id" FROM "exercises" WHERE ("name" = 'Back Squat')},
      %{SELECT "id" FROM "exercises" WHERE ("name" = '?')}
    ],
    'an account id and a limit' => [
      %{SELECT * FROM "workouts" WHERE ("account_id" = 407) ORDER BY "date" LIMIT 50},
      %{SELECT * FROM "workouts" WHERE ("account_id" = ?) ORDER BY "date" LIMIT ?}
    ],
    'a weight with a decimal point' => [
      %{UPDATE "sets" SET "weight" = 137.50 WHERE ("id" = 341437)},
      %{UPDATE "sets" SET "weight" = ? WHERE ("id" = ?)}
    ],
    'a negative bench angle' => [
      %{SELECT * FROM "program_lifts" WHERE ("bench_angle_degrees" BETWEEN -30 AND 90)},
      %{SELECT * FROM "program_lifts" WHERE ("bench_angle_degrees" BETWEEN ? AND ?)}
    ]
  }.freeze

  def scrub(sql) = Tectonic::ErrorReporting.scrub_sql(sql)
end

describe 'the values in a query span' do
  include Tracing

  Tracing::STATEMENTS.each do |what, (raw, scrubbed)|
    it "takes #{what} out" do
      assert_equal scrubbed, scrub(raw)
    end
  end

  # SQL's own escape for a quote inside a string is two quotes. A pattern that stopped at the
  # first one would end the match early and leave the tail of somebody's text behind, which is
  # the failure that looks like it worked.
  it 'takes the whole of a string containing an escaped quote' do
    said = %{SELECT * FROM "workouts" WHERE ("note" = 'it''s heavy, 225 felt awful')}

    assert_equal %{SELECT * FROM "workouts" WHERE ("note" = '?')}, scrub(said)
    refute_includes scrub(said), '225'
  end

  # Blanking these would turn a readable statement into a puzzle for no gain: there is nothing
  # of anybody's in an identifier or a parameter index.
  it 'leaves the index of a bound parameter alone' do
    assert_equal %(SELECT * FROM "t" WHERE "x" = $1), scrub(%(SELECT * FROM "t" WHERE "x" = $1))
  end

  it 'leaves a nil description alone rather than raising on it' do
    assert_nil scrub(nil)
  end
end

# Sentry groups spans by description, so this is not only a privacy fix. Without it,
# `account_id = 407` and `account_id = 408` are two different spans of one query, and the
# aggregate the whole feature exists for never forms.
describe 'what scrubbing does to the grouping' do
  include Tracing

  it 'makes one query out of the same query run for two accounts' do
    mine = %{SELECT * FROM "workouts" WHERE ("account_id" = 407)}
    theirs = %{SELECT * FROM "workouts" WHERE ("account_id" = 408)}

    assert_equal scrub(mine), scrub(theirs)
  end
end

describe 'the spans on a transaction' do
  include Tracing

  def event_with(spans)
    Struct.new(:spans).new(spans)
  end

  it 'scrubs a database span' do
    event = event_with([{ op: 'db.sql.sequel', description: %{SELECT * FROM "a" WHERE ("e" = 'x@y.z')} }])

    Tectonic::ErrorReporting.scrub_spans(event)

    assert_equal %{SELECT * FROM "a" WHERE ("e" = '?')}, event.spans.first[:description]
  end

  # Applied by prefix rather than to Sequel's op alone, so a database integration added later
  # is covered by something that already exists rather than by somebody remembering.
  it 'scrubs any database span, not only the one integration in use today' do
    event = event_with([{ op: 'db.redis', description: %(GET 'someone@example.com') }])

    Tectonic::ErrorReporting.scrub_spans(event)

    refute_includes event.spans.first[:description], 'someone@example.com'
  end

  # Their description is a method and a URL the SDK already sanitises, and blanking the
  # numbers in one would destroy the part worth reading.
  it 'leaves an http span alone' do
    event = event_with([{ op: 'http.client', description: 'GET https://api.example.com/v1/things/42' }])

    Tectonic::ErrorReporting.scrub_spans(event)

    assert_equal 'GET https://api.example.com/v1/things/42', event.spans.first[:description]
  end

  it 'copes with a transaction that has no spans at all' do
    Tectonic::ErrorReporting.scrub_spans(event_with(nil))
  end
end

# #388 carries a caveat worth respecting: a transaction holds a reference to the Rack env for
# its lifetime, and on a small instance that shows up as memory growth. Turning the rate down
# therefore has to be possible from a dashboard by somebody watching a graph climb, not by a
# commit and a deploy.
describe 'how much of the traffic is timed' do
  include Tracing

  after { ENV.delete('SENTRY_TRACES_SAMPLE_RATE') }

  # Everything, and deliberately not the 10% #388 suggested: with one active account, a tenth
  # is not a sample, it is a rounding error.
  it 'is all of it by default' do
    assert_in_delta 1.0, Tectonic::ErrorReporting.traces_sample_rate
  end

  it 'can be turned down without a deploy' do
    ENV['SENTRY_TRACES_SAMPLE_RATE'] = '0.25'

    assert_in_delta 0.25, Tectonic::ErrorReporting.traces_sample_rate
  end

  it 'can be switched off entirely, leaving the error half on' do
    ENV['SENTRY_TRACES_SAMPLE_RATE'] = '0'

    assert_in_delta 0.0, Tectonic::ErrorReporting.traces_sample_rate
  end

  # A typo meaning "100%" would be read by the SDK as an invalid rate and silently disable
  # tracing, which is the failure that looks like it worked.
  it 'clamps a value meant as a percentage rather than disabling itself' do
    ENV['SENTRY_TRACES_SAMPLE_RATE'] = '100'

    assert_in_delta 1.0, Tectonic::ErrorReporting.traces_sample_rate
  end
end

# Everything below runs against the real thing rather than against a string: the app's own
# configuration, the app's own database handle, a query this app actually makes, and the hook as
# `initialise` installs it.
#
# The unit tests above prove the regex. These prove the wiring -- that the integration is
# reached at all, that it attaches the SQL, and that what would leave the process has had the
# address taken out. Those are three separate things and the first one was broken.
module RealTracing
  # Sentry is global, so it is initialised per test and closed again. Left open, `on?` would
  # answer true for every spec that ran afterwards and the reporting hooks scattered through the
  # app would start trying to reach a network that is not there.
  #
  # Initialised through the real method, then given a transport that goes nowhere. Without the
  # swap this opens a network connection per transaction, which is exactly what
  # lib/tectonic/error_reporting.rb says it will not do -- "a suite that opened a network
  # connection per exception would be a suite nobody could run on a train". A spec that breaks
  # the rule whose enforcement it is testing is not much of a spec.
  #
  # The transport rather than `enabled_environments`, which was the first attempt and is the
  # wrong lever: that stops transactions being *created*, so `start_transaction` answers nil and
  # there is nothing left to assert about. Swapping the transport leaves everything `initialise`
  # set exactly as it set it -- the sample rate, the patches, the hook read back below -- and
  # only the sending stops. Reaching past a reader to do it, which a spec may do and production
  # code may not.
  def reporting_to_nowhere
    require 'sentry-ruby'
    Tectonic::ErrorReporting.initialise('https://public@example.ingest.sentry.io/1')
    Sentry.get_current_client
          .instance_variable_set(:@transport, Sentry::DummyTransport.new(Sentry.configuration))
  end

  def stop_reporting
    Sentry.close if defined?(Sentry) && Sentry.initialized?
  end

  def spans_of_a_query_for(email)
    transaction = Sentry.start_transaction(name: 'spec', op: 'http.server')
    Sentry.get_current_scope.set_span(transaction)
    DB[:accounts].where(email:).first
    transaction.finish
    transaction.span_recorder.spans.map(&:to_h)
  end

  def query_span_for(email)
    spans_of_a_query_for(email).find { |span| span[:op] == 'db.sql.sequel' }
  end

  # The event as `before_send_transaction` receives one: spans already flattened to hashes,
  # which is checked rather than assumed.
  def as_sent(email)
    event = Struct.new(:spans).new(spans_of_a_query_for(email))
    Sentry.configuration.before_send_transaction.call(event, nil)
    event.spans
  end
end

# The bug that made the whole feature silent: the gem patches `Sequel::Database`, which reaches
# future Database objects only, and this app's DB is built at require time.
describe 'whether a query is instrumented at all' do
  include RealTracing

  before { reporting_to_nowhere }
  after { stop_reporting }

  it 'produces a span, which it did not until the open database was instrumented' do
    refute_nil query_span_for('someone@example.com'),
               'no query span: the integration is not reaching this app\'s database'
  end
end

# And the reason the scrubber is not optional. Asserted so that a future version of the gem
# quietly starting to parameterise its queries would be a failing test rather than a silent
# change of meaning.
describe 'what the integration attaches before anything scrubs it' do
  include RealTracing

  before { reporting_to_nowhere }
  after { stop_reporting }

  it 'is the statement with the address still in it' do
    assert_includes query_span_for('someone@example.com')[:description], 'someone@example.com'
  end
end

describe 'what would actually leave the process' do
  include RealTracing

  before { reporting_to_nowhere }
  after { stop_reporting }

  it 'has no email address anywhere in it' do
    refute(as_sent('someone@example.com').any? { |span| span[:description].to_s.include?('someone@example.com') },
           'an email address survived into what would be sent to Sentry')
  end

  # Scrubbed, not blanked. A description with the values gone is still the query; a description
  # replaced wholesale would be privacy at the cost of the entire point.
  it 'still leaves the shape of the query readable' do
    sent = as_sent('someone@example.com').find { |span| span[:op] == 'db.sql.sequel' }[:description]

    assert_includes sent, 'FROM "accounts"'
    assert_includes sent, %q("email" = '?')
  end
end

