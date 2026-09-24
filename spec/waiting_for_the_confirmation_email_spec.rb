# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'confirming_the_address_spec' # sign_up, confirm, emailed_text; idempotent require

# #633. Sign-up landed on /login, where the biggest thing on the page asked for a password
# nobody had chosen, and sending the link again was reachable only by failing that sign-in.
module WaitingForTheEmail
  def rodauth_resend = '/verify-account-resend'

  def resend_token = last_response.body[/id="resend-form".*?name="_csrf" value="([^"]+)"/m, 1]

  def resend(email)
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { @emailed = [to, subject, text] and true }) do
      post rodauth_resend, { login: email, '_csrf' => resend_token }
    end
  end
end

describe 'what the page a sign-up waits on says' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming
  include WaitingForTheEmail

  before do
    @email = sign_up
    follow_redirect!
  end

  it 'names the address the link went to, so a typo shows' do
    assert_includes last_response.body, @email
  end

  it 'says the password is chosen from the link, not asked for here' do
    assert_includes last_response.body, 'that is where you choose your password'
    refute_includes last_response.body, 'type="password"'
  end

  it 'mentions junk mail' do
    assert_includes last_response.body, 'junk or spam'
  end

  it 'offers a way to start over with another address' do
    assert_includes last_response.body, 'href="/create-account"'
  end
end

describe 'what the page a sign-up waits on does' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming
  include WaitingForTheEmail

  before do
    @email = sign_up
    follow_redirect!
  end

  it 'sends the link again, and comes back here' do
    resend(@email)

    assert_equal @email, @emailed.first
    assert_equal '/check-your-email', URI(last_response.location).path
  end

  # The link still does what it did: it signs the account in and leaves this page behind.
  it 'is left behind once the link is used' do
    confirm(confirmation_key)
    follow_redirect! while last_response.redirect?

    refute_equal '/check-your-email', last_request.path
  end
end

# The address comes from the signing-up browser's own session, and nobody else gets the page.
describe 'the waiting page, from a browser that did not sign up' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'sends them to sign in' do
    get '/check-your-email'

    assert_equal '/login', URI(last_response.location).path
  end
end

