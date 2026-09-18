# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/withings'
require_relative '../lib/tectonic/withings_connection'

# Handing Withings permission to be read. #472.
#
# Nothing here talks to Withings. You cannot meaningfully test somebody else's OAuth server,
# only this app's handling of what it sends back -- so the exchange is stubbed and what is
# asserted is the four outcomes a lifter can tell apart, the state check that makes the
# callback safe, and what disconnecting does and does not delete.
module ConnectingAScale
  CREDENTIALS = { 'WITHINGS_CLIENT_ID' => 'id-for-the-suite',
                  'WITHINGS_SECRET' => 'secret-for-the-suite' }.freeze

  # A deployment that has credentials, and one that has none.
  #
  # Both set the environment explicitly rather than relying on what is already there, and
  # that is not fussiness: `dotenv/load` runs in app.rb, so a developer with real Withings
  # credentials in .env has them present in the suite while CI does not. A test that read
  # the ambient value would pass on one machine and fail on the other, which is the worst
  # way for a test to be wrong.
  def with_env(values)
    was = CREDENTIALS.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    CREDENTIALS.each_key { |key| values[key] ? ENV[key] = values[key] : ENV.delete(key) }
    yield
  ensure
    was.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_credentials(&) = with_env(CREDENTIALS, &)
  def without_credentials(&) = with_env({}, &)

  # What Withings answers a successful exchange with. `expires_in` rather than an instant is
  # theirs, not ours -- which is why the column holds a computed time instead.
  def tokens(expires_in: 10_800)
    { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
      'expires_in' => expires_in, 'userid' => '9001' }
  end

  def connect
    post '/settings/withings/connect',
         { '_csrf' => token_for_form('/settings', '/settings/withings/connect') }
  end

  def callback(state:, code: 'the-code')
    get '/withings/callback', { 'state' => state, 'code' => code }
  end

  # The state the connect redirect put in the session, read back out of it.
  def issued_state
    connect
    last_response.headers['location'][/[?&]state=([^&]+)/, 1]
  end

  def stored(account_id) = DB[:account_withings].where(account_id:).first
end

describe 'starting a connection' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'sends the lifter to Withings' do
    with_credentials { connect }

    assert_includes last_response.headers['location'], 'account.withings.com'
  end

  # The two scopes #472 settled. user.info is deliberately absent: it needs a contract with
  # Withings and its presence fails the whole authorisation.
  it 'asks for the metrics and activity scopes and nothing else' do
    with_credentials { connect }
    scope = CGI.unescape(last_response.headers['location'][/scope=([^&]+)/, 1])

    assert_equal 'user.metrics,user.activity', scope
  end

  it 'does not ask for user info, which needs a contract' do
    with_credentials { connect }

    refute_includes CGI.unescape(last_response.headers['location']), 'user.info'
  end

  # A deployment with no credentials has nothing to send anybody to, and must not send them
  # to a half-built URL to find out.
  #
  # The token is minted while the credentials are present and spent while they are not, which
  # is fiddly and is the honest way round: with none set the page does not draw the Connect
  # form at all, so there is no form for the CSRF helper to read a token out of. That is the
  # belt; this asserts the braces behind it.
  it 'goes nowhere when the deployment has no credentials' do
    csrf = with_credentials { token_for_form('/settings', '/settings/withings/connect') }
    without_credentials { post '/settings/withings/connect', { '_csrf' => csrf } }

    assert_includes last_response.headers['location'], '/settings'
    refute_includes last_response.headers['location'], 'withings.com'
  end
end

# And the page says why rather than drawing a button that cannot work.
describe 'a deployment with no Withings credentials' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'says there is nothing to connect to' do
    without_credentials { get '/settings' }

    assert_includes last_response.body, 'no Withings credentials'
  end
end

# The state parameter, which is the only thing tying the callback to the browser that began
# the flow. Without it anyone can send a logged-in lifter to the callback with a code of
# their own and attach their Withings account to this one.
describe 'a callback that did not come from this browser' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'refuses a state that does not match' do
    with_credentials do
      issued_state
      callback(state: 'a-state-from-somewhere-else')
    end

    assert_nil stored(@account_id)
  end

  it 'refuses a callback with no state at all' do
    with_credentials { callback(state: '') }

    assert_nil stored(@account_id)
  end

  # Single use, so a code cannot be replayed against a state that already worked.
  it 'refuses the same state twice' do
    with_credentials do
      state = issued_state
      Tectonic::Withings.stub(:exchange, tokens) { callback(state:) }
      Tectonic::WithingsConnection.forget(@account_id)
      callback(state:)
    end

    assert_nil stored(@account_id)
  end
end

# Each refusal says which one it was. Four outcomes a lifter can tell apart is the difference
# between a page that worked and a page that silently did nothing.
describe 'what the callback says when it refuses' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'says so rather than failing silently' do
    with_credentials { callback(state: 'wrong') }
    follow_redirect!

    assert_includes last_response.body, 'did not match this browser'
  end
end

describe 'a callback that did come from this browser' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'stores the tokens' do
    with_credentials do
      state = issued_state
      Tectonic::Withings.stub(:exchange, tokens) { callback(state:) }
    end

    assert_equal 'access-1', stored(@account_id)[:access_token]
    assert_equal '9001', stored(@account_id)[:withings_user_id]
  end

  # Withings answers with a duration; a column holding "10800" would be meaningless the
  # moment it was read, so the instant is computed once on the way in.
  it 'turns the duration into an instant' do
    with_credentials do
      state = issued_state
      Tectonic::Withings.stub(:exchange, tokens(expires_in: 3600)) { callback(state:) }
    end

    assert_in_delta Time.now + 3600, stored(@account_id)[:expires_at], 60
  end
end

# The lifter pressing cancel, and Withings having a bad afternoon, are different from each
# other and from success -- and none of them should leave a half-written connection.
describe 'a callback that came back empty-handed' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'says nothing was granted when the code is missing' do
    with_credentials do
      state = issued_state
      callback(state:, code: '')
    end
    follow_redirect!

    assert_nil stored(@account_id)
    assert_includes last_response.body, 'did not grant access'
  end

  it 'says it could not be reached when the exchange fails' do
    with_credentials do
      state = issued_state
      Tectonic::Withings.stub(:exchange, nil) { callback(state:) }
    end
    follow_redirect!

    assert_nil stored(@account_id)
    assert_includes last_response.body, 'could not be reached'
  end
end

# Disconnecting forgets the permission and keeps the measurements: they are a record of what
# the lifter weighed, which stays true whether or not the app may still ask for more.
describe 'disconnecting' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before do
    @account_id = login
    Tectonic::WithingsConnection.store(@account_id, tokens)
    DB[:health_metrics].insert(account_id: @account_id, metric: 'weight', value: 81.4,
                               unit: 'kg', measured_at: Time.now, source: 'withings',
                               external_id: 'w-1')
  end

  def disconnect
    post '/settings/withings/disconnect',
         { '_csrf' => token_for_form('/settings', '/settings/withings/disconnect') }
  end

  it 'forgets the tokens' do
    disconnect

    assert_nil stored(@account_id)
  end

  it 'keeps what was already measured' do
    disconnect

    assert_equal 1, DB[:health_metrics].where(account_id: @account_id).count
  end
end

# Three states rather than two. A grant revoked from Withings' own app leaves a row that no
# longer buys anything, and a page saying "connected" about it would be wrong in the one way
# that is hard to notice: readings simply stop arriving.
describe 'what the page can tell apart' do
  include Rack::Test::Methods
  include RouteOwnership
  include ConnectingAScale

  before { @account_id = login }

  it 'is absent before anybody connects' do
    assert_equal :absent, Tectonic::WithingsConnection.status(@account_id)[:state]
  end

  it 'is live while the permission holds' do
    Tectonic::WithingsConnection.store(@account_id, tokens)

    assert_equal :live, Tectonic::WithingsConnection.status(@account_id)[:state]
  end

  it 'is stale once it has expired' do
    Tectonic::WithingsConnection.store(@account_id, tokens(expires_in: -60))

    assert_equal :stale, Tectonic::WithingsConnection.status(@account_id)[:state]
  end

  # A caller getting nil should say the connection needs renewing rather than retry, which is
  # why a failed refresh is nil rather than the dead token.
  it 'hands out no token when the refresh fails' do
    Tectonic::WithingsConnection.store(@account_id, tokens(expires_in: -60))

    Tectonic::Withings.stub(:refresh, nil) do
      assert_nil Tectonic::WithingsConnection.token(@account_id)
    end
  end

  it 'hands out the live one without refreshing' do
    Tectonic::WithingsConnection.store(@account_id, tokens)

    assert_equal 'access-1', Tectonic::WithingsConnection.token(@account_id)
  end
end

