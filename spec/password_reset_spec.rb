# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #344: a forgotten password lost the account outright. There was no reset flow, and two
# comments in the tree said so -- views/login.erb had removed its "Forgot password?" link
# rather than leave it pointing at nothing, and app.rb gave the missing mailer as the reason
# the password-confirmation box was worth arguing about.
#
# #345 made it worse before this made it better: one email is now one account, so somebody
# who has lost their password can no longer sign up again with the same address and start
# over. The two changes are only both right together.
module Reset
  # The request, with the email captured rather than sent. Capturing it is the point: the
  # token under test is the one a person actually receives, not one rebuilt from the row --
  # a rebuilt token would still pass if Rodauth changed how it derives the link, which is
  # exactly the change that would break the feature for everybody.
  def ask_for_reset(email)
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { @emailed = [to, subject, text] and true }) do
      get '/reset-password-request'
      post '/reset-password-request', { login: email, '_csrf' => token_from(last_response.body) }
    end
    @emailed
  end

  def emailed_text = @emailed&.last

  # The key out of the link that was emailed.
  def emailed_key
    emailed_text[/[?&]key=([^\s&]+)/, 1]
  end

  def reset_row(email)
    account_id = DB[:accounts].where(email:).get(:id)
    DB[:account_password_reset_keys].where(id: account_id).first
  end

  # Two requests, because Rodauth answers the link with a redirect to the bare route: it
  # moves the key into the session first, so the token leaves the address bar and cannot
  # leak through a Referer header on whatever the next page loads. The form is on the second
  # response, and so is the CSRF token the post needs.
  def use_token(token, password:)
    get "/reset-password?key=#{token}"
    follow_redirect! while last_response.redirect?
    # No key in the post: by now it is in the session, which is what the redirect above was
    # for. Sending it would test a path the real form does not use.
    post '/reset-password', { password:, '_csrf' => token_from(last_response.body) }
  end

  def sign_in(email, password)
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
  end
end

describe 'asking for a reset link' do
  include Rack::Test::Methods
  include RouteOwnership
  include Reset

  it 'writes a token for an address that has an account' do
    email, = make_account
    ask_for_reset(email)

    refute_nil reset_row(email), 'no reset key was written'
  end

  # Rodauth's default and kept deliberately. A form that answers "no such account" tells
  # anybody which of a list of addresses lift here, and what people lift is exactly what this
  # app should not be an oracle for.
  it 'answers a stranger the same way it answers a member' do
    email, = make_account
    ask_for_reset(email)
    known = [last_response.status, last_response.headers['location']]

    ask_for_reset("nobody-#{SecureRandom.hex}@example.com")

    assert_equal known, [last_response.status, last_response.headers['location']]
  end

  it 'writes nothing for an address with no account' do
    stranger = "nobody-#{SecureRandom.hex}@example.com"
    ask_for_reset(stranger)

    assert_equal 0, DB[:account_password_reset_keys].count
  end
end

describe 'using the link' do
  include Rack::Test::Methods
  include RouteOwnership
  include Reset

  before do
    @email, @old = make_account
    ask_for_reset(@email)
    @token = emailed_key
  end

  it 'sets the new password' do
    use_token(@token, password: 'brand-new-pw-9876')
    sign_in(@email, 'brand-new-pw-9876')

    assert_equal 302, last_response.status
  end

  it 'stops the old password working' do
    use_token(@token, password: 'brand-new-pw-9876')
    sign_in(@email, @old)

    assert_equal 401, last_response.status
  end
end

# The three ways a link should not work, which are the whole security surface of a reset
# flow: reuse, forgery, and age.
describe 'a link that should not work' do
  include Rack::Test::Methods
  include RouteOwnership
  include Reset

  before do
    @email, @old = make_account
    ask_for_reset(@email)
    @token = emailed_key
  end

  # One use. A reset link sits in an inbox afterwards, and an inbox is not a safe place to
  # leave a working key to an account.
  it 'cannot be used twice' do
    use_token(@token, password: 'brand-new-pw-9876')
    use_token(@token, password: 'second-attempt-5432')
    sign_in(@email, 'second-attempt-5432')

    assert_equal 401, last_response.status
  end

  it 'refuses a token that was never issued' do
    row = reset_row(@email)
    use_token("#{row[:id]}_#{SecureRandom.hex(32)}", password: 'forged-pw-0000')
    sign_in(@email, 'forged-pw-0000')

    assert_equal 401, last_response.status
  end
end

describe 'a link that has aged out' do
  include Rack::Test::Methods
  include RouteOwnership
  include Reset

  before do
    @email, @old = make_account
    ask_for_reset(@email)
    @token = emailed_key
  end

  # The deadline is a column with a default of a day, so an expired link is a row in the
  # past rather than a branch in the code. Aged directly, since the alternative is waiting.
  it 'refuses a token that has expired' do
    DB[:account_password_reset_keys].where(id: reset_row(@email)[:id])
                                    .update(deadline: Time.now - 60)
    use_token(@token, password: 'too-late-pw-1111')
    sign_in(@email, 'too-late-pw-1111')

    assert_equal 401, last_response.status
  end
end

describe 'the way in from the sign-in page' do
  include Rack::Test::Methods
  include RouteOwnership

  # The link was removed rather than left pointing at nothing, with a note saying it belonged
  # back "once reset_password is enabled and a mail provider is wired up, and not before".
  it 'offers a forgotten-password link that goes somewhere' do
    get '/login'

    assert_includes last_response.body, 'Forgot password?'
    assert_includes last_response.body, 'href="/reset-password-request"'
  end

  it 'serves the page that link points at' do
    get '/reset-password-request'

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Reset your password'
  end
end

# lib/tectonic/mailer.rb, which is deliberately quiet in both of the ways it can fail.
describe 'the mailer' do
  # Unconfigured is the suite, development, and any checkout that has never sent an email.
  # It logs the link rather than raising, so the flow stays walkable without a key.
  it 'does not raise when there is no API key' do
    refute Tectonic::Mailer.configured?
    assert_silent_failure { Tectonic::Mailer.deliver(to: 'a@example.com', subject: 'x', text: 'y') }
  end

  # The important one. Rodauth calls the mailer from inside the reset form's POST and has
  # already written the token by then, so an exception here would 500 the page while the
  # emailed link worked -- telling somebody their address was wrong when the provider was
  # merely down.
  it 'reports a transport failure instead of raising it into the request' do
    Tectonic::Mailer.stub(:configured?, true) do
      Tectonic::Mailer.stub(:post, ->(**) { raise Errno::ECONNREFUSED }) do
        assert_silent_failure { Tectonic::Mailer.deliver(to: 'a@example.com', subject: 'x', text: 'y') }
      end
    end
  end

  # Returns false rather than true, so the log and the specs can tell a send from a
  # non-send even though the page says the same thing either way.
  def assert_silent_failure
    result = nil
    capture_io { result = yield }

    refute result
  end
end

describe 'what the reset email says' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @body = Tectonic.new({}).reset_password_body('https://tectonicplates.app/reset-password?key=7_abc') }

  it 'carries the link' do
    assert_includes @body, 'https://tectonicplates.app/reset-password?key=7_abc'
  end

  # The two questions somebody receiving an unexpected one actually has.
  it 'says how long it lasts and what to do if it was not you' do
    assert_includes @body, '24 hours'
    assert_includes @body, 'was not you'
  end

  # It does not stop at "ignore this email": a reset nobody asked for is worth knowing about.
  it 'says the current password still works' do
    assert_includes @body, 'current password still works'
  end
end

