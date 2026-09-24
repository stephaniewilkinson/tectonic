# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'oauth_spec' # register_client, consent_page; idempotent require
require_relative 'confirming_the_address_spec' # sign_up, confirm; idempotent require

# #628. Pressing Connect in Claude without being signed in here sent a lifter to sign in, and
# signing in landed them on /start -- never on the consent screen the assistant was waiting on.
# Every OAuth spec signed in first, so none of them could see it. These start signed out.
module ConnectingSignedOut
  def the_consent_screen? = last_response.body.include?('name="scope[]"')

  # The connection made, as a grant row, which is all the note on /start asks about.
  def granted(email, client)
    application_id = DB[:oauth_applications].where(client_id: client['client_id']).get(:id)
    DB[:oauth_grants].insert(account_id: DB[:accounts].where(email:).get(:id), oauth_application_id: application_id,
                             scopes: 'read', code: SecureRandom.hex, redirect_uri: client['redirect_uris'].first,
                             expires_in: Time.now + 60)
  end

  def token_from(body) = body[/name="_csrf"[^>]*value="([^"]*)"/, 1]

  def land
    follow_redirect! while last_response.redirect?
  end
end

describe 'connecting an assistant from an account that is signed out' do
  include Rack::Test::Methods
  include OAuthFlow
  include Confirming
  include ConnectingSignedOut

  it 'comes back to the consent screen after signing in' do
    _, email, password = create_account
    client = register_client
    consent_page(client)
    assert_equal '/login', URI(last_response.location).path

    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
    assert URI(last_response.location).path.end_with?('/authorize'), "went to #{last_response.location}"
    land

    assert the_consent_screen?, 'signed in and never shown the consent screen'
  end

  # A background request is not somewhere to come back to. The session screen polls; if the
  # session has gone, the poll must not become the page the next sign-in lands on.
  it 'does not come back to a background request' do
    _, email, password = create_account
    get '/workouts/1/session/changes?since=x', {}, { 'HTTP_HX_REQUEST' => 'true' }
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }

    refute_includes last_response.location.to_s, '/changes'
  end
end

describe 'connecting an assistant by signing up for an account first' do
  include Rack::Test::Methods
  include OAuthFlow
  include Confirming
  include ConnectingSignedOut

  before do
    @client = register_client
    consent_page(@client)
    @email = sign_up
  end

  it 'comes back to the consent screen when the link is opened in the same browser' do
    confirm(confirmation_key)
    land

    assert the_consent_screen?, 'confirmed the address and never shown the consent screen'
  end
end

# The emailed link opened on a phone, or in a mail app's own browser: nothing of this session
# comes with it, so the consent screen cannot follow. /start says what happened instead.
describe 'signing up to connect an assistant, and opening the link somewhere else' do
  include Rack::Test::Methods
  include OAuthFlow
  include Confirming
  include ConnectingSignedOut

  before do
    @client = register_client
    consent_page(@client)
    @email = sign_up
    key = confirmation_key
    clear_cookies
    confirm(key)
    land
  end

  it 'says which assistant was being connected, and what to do' do
    assert_equal '/start', last_request.path
    assert_includes last_response.body, 'You were connecting Claude'
  end

  it 'stops saying so once the assistant is connected' do
    granted(@email, @client)
    get '/start'

    refute_includes last_response.body, 'You were connecting'
  end
end

describe 'signing up without an assistant in the picture' do
  include Rack::Test::Methods
  include OAuthFlow
  include Confirming
  include ConnectingSignedOut

  it 'says nothing about connecting one' do
    sign_up
    key = confirmation_key
    clear_cookies
    confirm(key)
    follow_redirect! while last_response.redirect?

    refute_includes last_response.body, 'You were connecting'
  end
end

