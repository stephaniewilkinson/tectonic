# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # make_account, token_from; idempotent require

# Security pass, 2026-09-25: sign-in had no limit on wrong passwords, so one could be guessed at
# forever. Ten wrong in a row now locks the account for an hour, with an emailed link to lift it.
module GuessingAPassword
  def attempt(email, password)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
  end

  # The emailed link, followed and confirmed the way a person clicking it would.
  def open_the_link(text)
    get text[%r{https?://\S*/unlock-account\?key=\S+}].sub(%r{\Ahttps?://[^/]+}, '')
    follow_redirect! while last_response.redirect?
    post '/unlock-account',
         { '_csrf' => last_response.body[/id="unlock-account-form".*?name="_csrf" value="([^"]+)"/m, 1] }
  end

  def guessed_wrong(email, times) = times.times { attempt(email, 'not-the-password') }

  def unlock_mail(email)
    sent = nil
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { sent = [to, subject, text] and true }) do
      attempt(email, 'still-wrong')
      post '/unlock-account-request',
           { login: email,
             '_csrf' => last_response.body[/id="unlock-account-request-form".*?name="_csrf" value="([^"]+)"/m, 1] }
    end
    sent
  end
end

describe 'guessing at a password' do
  include Rack::Test::Methods
  include RouteOwnership
  include GuessingAPassword

  before { @email, @password = make_account }

  it 'is stopped after ten wrong, even when the eleventh is right' do
    guessed_wrong(@email, 10)
    attempt(@email, @password)

    assert_includes last_response.body, 'This account is locked'
    refute_equal '/start', last_response.location
  end

  it 'is not stopped by a few wrong before the right one' do
    guessed_wrong(@email, 3)
    attempt(@email, @password)

    assert_equal 302, last_response.status
    refute_includes last_response.body, 'locked'
  end

  it 'lets the owner back in straight away from the emailed link' do
    guessed_wrong(@email, 10)
    to, subject, text = unlock_mail(@email)

    assert_equal @email, to
    assert_includes subject, 'locked'
    open_the_link(text)

    assert_nil DB[:account_lockouts].where(id: DB[:accounts].where(email: @email).get(:id)).first
  end
end

