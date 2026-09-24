# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# #575: signing up needed nothing but the form, so an address never had to exist, let alone
# belong to the person typing it. 410 accounts, 409 of which have never logged a set, and
# `reset_password` really sends -- so every one of those addresses could be made to receive
# mail from this domain by anybody who knew it.
#
# This is the highest-risk change this app has made, because the mechanism Rodauth uses is a
# status column `accounts` has never had, and `verify_account` turns on four code paths
# against it at once. Get it wrong and sign-up, login and every authenticated request are
# `PG::UndefinedColumn`. So the first describe here is not about the feature at all: it is
# about everybody who already had an account still having one.
module Confirming
  # Sign-up with the email captured rather than sent. Capturing it is the point, and it is the
  # same argument password_reset_spec makes: the token under test has to be the one a person
  # actually receives, not one rebuilt from the row. A rebuilt token would still pass if
  # Rodauth changed how it derives the link, which is exactly the change that breaks the
  # feature for everybody.
  def sign_up(email = "#{SecureRandom.hex}@example.com")
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { @emailed = [to, subject, text] and true }) do
      get '/create-account'
      # No password: the form does not have a box for one, and Rodauth would ignore it if it
      # did. It is chosen on the page the emailed link leads to.
      post '/create-account', { login: email, '_csrf' => token_from(last_response.body) }
    end
    email
  end

  def emailed_text = @emailed&.last

  def emailed_link = emailed_text[%r{https?://\S*/verify-account\?key=\S+}]

  def confirmation_key = emailed_text[/[?&]key=([^\s&]+)/, 1]

  # Two requests, because Rodauth answers the link with a redirect to the bare route: it moves
  # the key into the session first, so the token leaves the address bar and cannot leak
  # through a Referer header on whatever the next page loads. The form is on the second
  # response, and so is the CSRF token the post needs.
  #
  # The password goes here rather than to the sign-up form, which is the whole shape of the
  # flow: the row exists with no credential until this post lands.
  def confirm(key, password: 'chosen-later-9876')
    get "/verify-account?key=#{key}"
    follow_redirect! while last_response.redirect?
    post '/verify-account', { password:, '_csrf' => token_from(last_response.body) }
  end

  def resend(email)
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { @emailed = [to, subject, text] and true }) do
      get '/verify-account-resend'
      post '/verify-account-resend', { login: email, '_csrf' => token_from(last_response.body) }
    end
  end

  def sign_in(email, password = 'pw12345678')
    get '/login'
    post '/login', { login: email, password:, '_csrf' => token_from(last_response.body) }
  end

  # A real logout, which is a POST; the GET renders the confirmation page and ends nothing.
  # Confirming signs the person in, so anything asserted after it that has to be done signed
  # out goes through here first.
  def log_out
    get '/logout'
    post '/logout', { '_csrf' => token_from(last_response.body) }
  end

  def ask_for_reset(email)
    Tectonic::Mailer.stub(:deliver, ->(to:, subject:, text:) { @emailed = [to, subject, text] and true }) do
      get '/reset-password-request'
      post '/reset-password-request', { login: email, '_csrf' => token_from(last_response.body) }
    end
  end

  def status_of(email) = DB[:accounts].where(email:).get(:status_id)

  def key_row(email)
    DB[:account_verification_keys].where(id: DB[:accounts].where(email:).get(:id)).first
  end

  def alert_text = last_response.body[/role="alert"[^>]*>\s*([^<]+)/, 1].to_s.strip

  # The other half of that, and a different role on purpose: `_flash_notice` says
  # role="status" because a confirmation is not a problem. See the partial's own note.
  def notice_text = last_response.body[/role="status"[^>]*>\s*([^<]+)/, 1].to_s.strip
end

# The one that would be a total outage. Every account in production predates this change and
# none of them has ever had a status, so the question is not "does verification work" but
# "does the owner still have an account tomorrow morning".
describe 'an account that existed before any of this' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  # make_account inserts straight into the table, which is what migrate/051's default governs
  # and what fifty-eight other spec files do. It is also, near enough, what a row written
  # during the deploy window looks like: created by code that knew nothing about a status.
  it 'is open, because the column defaults to open rather than to unconfirmed' do
    email, = make_account

    assert_equal 2, status_of(email)
  end

  it 'can still log in, with no key row and nothing having been confirmed' do
    email, password = make_account
    sign_in(email, password)

    assert_equal 302, last_response.status
  end

  it 'can still reach a page that requires a session' do
    email, password = make_account
    sign_in(email, password)
    get '/workouts'

    assert last_response.ok?
  end
end

describe 'signing up' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  it 'creates the account' do
    email = sign_up

    assert_equal 1, DB[:accounts].where(email:).count
  end

  # The shape of the whole change, and the claim migrate/051 dropped a NOT NULL constraint
  # for. What sign-up writes is not an account that happens to be shut; it is a row with no
  # credential in it at all, which is what makes a sign-up nobody asked for cost nothing.
  it 'writes no password, because there is nowhere yet to have typed one' do
    email = sign_up

    assert_nil DB[:accounts].where(email:).get(:password_hash)
  end

  it 'leaves the account unconfirmed' do
    email = sign_up

    assert_equal 1, status_of(email)
  end

  it 'writes a key to confirm it with' do
    email = sign_up

    refute_nil key_row(email)
  end

  # The whole point. Sign-up used to log you straight in, which is why a bot's 410 rows were
  # 410 usable accounts rather than 410 rows waiting on an email nobody would open.
  it 'does not log anybody in' do
    sign_up
    get '/workouts'

    assert_equal 302, last_response.status
    assert_includes last_response.headers['location'], '/login'
  end
end

describe 'what a sign-up is told on the way out' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  # Pressing Sign up now empties the form and returns the sign-in page, which without a
  # notice is indistinguishable from the button being broken -- while the one instruction
  # that matters is "go and read your email". This app rendered no notice flash anywhere
  # until views/_flash_notice.erb, so the sentence Rodauth has always set was set into a void.
  it 'says what to do next, on the page it lands on' do
    sign_up
    follow_redirect!

    assert_includes notice_text, 'Check your email'
  end

  # The same silence the other way round, and the one that was already there: #344's reset
  # request has always redirected with "if there is an account, a link is on the way" and
  # that sentence has never once reached a screen. Pinned here because it is the same
  # partial, and because the reset form's non-oracle answer is worth nothing if the answer
  # is invisible.
  it 'says the same kind of thing after a reset request, which nothing rendered before' do
    email = sign_up
    ask_for_reset(email)
    follow_redirect!

    refute_empty notice_text
  end
end

describe 'a password posted to the sign-up form anyway' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  # Belt and braces on "writes no password", from the form's side rather than the column's.
  # Rodauth ignores a password parameter while `create_account_set_password?` is false, so a
  # box put back on views/create-account.erb would be collected and silently dropped, and
  # somebody would have typed a credential that is stored nowhere and then found it does not
  # work. Asserted because that failure leaves no trace anywhere else.
  it 'is ignored rather than half-used' do
    email = "#{SecureRandom.hex}@example.com"
    Tectonic::Mailer.stub(:deliver, ->(**) { true }) do
      get '/create-account'
      post '/create-account', { login: email, password: 'typed-into-nothing',
                                '_csrf' => token_from(last_response.body) }
    end

    assert_nil DB[:accounts].where(email:).get(:password_hash)
  end
end

describe 'the message a sign-up sends' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  it 'goes to the address that was typed, and says what the link is for' do
    email = sign_up

    assert_equal email, @emailed.first
    assert_includes @emailed[1], 'Confirm'
  end

  it 'carries a link that names this app rather than a bare path' do
    sign_up

    assert_match %r{\Ahttps?://\S+/verify-account\?key=}, emailed_link
  end
end

describe 'an account that has not been confirmed' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before { @email = sign_up }

  # There is no right password to try, which is the point: the row has a null hash, and
  # `password_match?` returns nil the moment `get_password_hash` does (`base.rb:488`). No
  # string gets in, and neither does the empty one -- which is the question a nullable
  # credential column has to answer before it is allowed anywhere near this table.
  it 'cannot be signed in to with any password' do
    ['', 'pw12345678', 'anything at all'].each do |attempt|
      sign_in(@email, attempt)

      refute_equal 302, last_response.status, "#{attempt.inspect} got in"
    end
  end

  it 'is not signed in to by a failed attempt either' do
    sign_in(@email, 'pw12345678')
    get '/workouts'

    assert_equal 302, last_response.status
  end

  # The question #575 asks and says should be answered rather than discovered: may an
  # unconfirmed account authorise an MCP client? It cannot, and the reason is that it has no
  # session at all -- which is the whole argument for not enabling verify_account_grace_period,
  # since a grace period restores create_account_autologin? and opens exactly this window.
  # Asserted from the outside rather than by reading `require_account`, because the claim is
  # about the consent screen and not about which method guards it.
  it 'cannot reach the screen that hands an API client the account' do
    sign_in(@email)
    get '/authorize'

    assert_equal 302, last_response.status
    assert_includes last_response.headers['location'], '/login'
  end
end

# Where a real person who never got the email is put, and the reason the resend page is not
# optional: without it Rodauth's unstyled built-in renders inside this app's layout, and the
# one screen standing between somebody and their account is the one that looks broken.
describe 'the way back for somebody whose link never arrived' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before { @email = sign_up }

  # Rodauth returns the resend view in place of the login form (`verify_account.rb:275-282`),
  # which is the whole reason the login oracle is worth accepting: this is the page a person
  # who cannot get in will reach by doing the obvious thing.
  it 'is answered at the login form with the way to get another link' do
    sign_in(@email)

    assert_includes last_response.body, 'verify-account-resend-form'
  end

  # Carried through as a hidden field rather than asked for a second time, which is what
  # Rodauth's own template does and is worth keeping: somebody who has just failed to log in
  # should not have to retype the address to ask for the link.
  it 'does not make that person type the address again' do
    sign_in(@email)

    assert_includes last_response.body, %(value="#{@email}")
  end
end

describe 'confirming the address' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before do
    @email = sign_up
    @key = confirmation_key
  end

  it 'opens the account' do
    confirm(@key)

    assert_equal 2, status_of(@email)
  end

  # The other half of "writes no password": the hash that was null a moment ago is the one the
  # account is signed in with from here on, and it was typed on this page rather than the
  # sign-up form.
  it 'is where the password gets set, and it is the one that then works' do
    confirm(@key, password: 'chosen-here-4321')
    log_out
    sign_in(@email, 'chosen-here-4321')

    assert_equal 302, last_response.status
    refute_nil DB[:accounts].where(email: @email).get(:password_hash)
  end

  # verify_account_autologin? is Rodauth's default and is left on, so the click that confirms
  # is also the way in. Landing on /start is login_destination's answer for an account with
  # nothing logged, and it is asserted here because moving the zone hook to
  # verify_account_redirect is what makes this the first request with a session in it.
  it 'signs the person in and lands them on the first-run page' do
    confirm(@key)

    assert_equal '/start', last_response.headers['location']
  end
end

# The link itself: what it leaves behind in the address bar, and the two ways it should not
# work, which are most of the security surface of this flow.
describe 'the link in the confirmation email' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before do
    @email = sign_up
    @key = confirmation_key
  end

  # The argument views/reset-password.erb makes about its own missing key field, applied here.
  it 'takes the key out of the address bar before showing the button' do
    get "/verify-account?key=#{@key}"

    assert_equal 302, last_response.status
    refute_includes last_response.headers['location'], 'key='
  end

  # Rodauth rotates the key rather than deleting the row (`verify_account.rb:249-261`), which
  # is not what reading the flow suggests and is worth pinning rather than rediscovering: the
  # row survives confirmation carrying a fresh key, and only `close_account` removes it. The
  # link in the inbox is dead either way, which is the part that matters, and the surviving
  # key opens nothing because `_account_from_verify_account_key` filters on the unconfirmed
  # status (`verify_account.rb:318-320`) and the account is no longer in it.
  it 'rotates the key once it has been used, so the link in the inbox is dead' do
    confirm(@key)

    refute_equal @key, "#{key_row(@email)[:id]}_#{key_row(@email)[:key]}"
  end
end

# The two ways a link should not work, which are most of the security surface of this flow:
# reuse and forgery. Age is the third and does not apply -- migrate/051 gives the key no
# deadline, and the note there says why.
describe 'a confirmation link that should not open an account' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before do
    @email = sign_up
    @key = confirmation_key
  end

  # A password the app would refuse anywhere else is refused here too, and refusing it must
  # not spend the link: somebody who types five characters has to be able to try again, and
  # this is the only page in the flow where they can.
  it 'is not spent by a password that does not meet the requirements' do
    confirm(@key, password: 'short')

    assert_equal 1, status_of(@email)

    confirm(@key, password: 'long-enough-8765')

    assert_equal 2, status_of(@email)
  end

  it 'cannot be used twice' do
    confirm(@key)
    log_out
    confirm(@key)

    refute_equal '/start', last_response.headers['location']
  end

  it 'refuses a key that was never issued' do
    account_id = DB[:accounts].where(email: @email).get(:id)
    confirm("#{account_id}_#{SecureRandom.hex(32)}")

    assert_equal 1, status_of(@email)
  end
end

describe 'asking for the link again' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before do
    @email = sign_up
    # The first send stamps email_last_sent, and Rodauth refuses another within 300 seconds.
    # Aged directly, since the alternative is waiting five minutes.
    DB[:account_verification_keys].where(id: key_row(@email)[:id]).update(email_last_sent: Time.now - 400)
    @emailed = nil
  end

  it 'sends another one' do
    resend(@email)

    assert_equal @email, @emailed&.first
  end

  it 'sends a link that works' do
    resend(@email)
    confirm(confirmation_key)

    assert_equal 2, status_of(@email)
  end

  # The throttle is the difference between a resend form and a way to send somebody a hundred
  # emails, and the address is not even the sender's. Same column, same 300 seconds, same
  # argument as the one on account_password_reset_keys in migrate/028.
  it 'refuses to send a second one straight away' do
    resend(@email)
    @emailed = nil
    resend(@email)

    assert_nil @emailed
  end
end

# app.rb argues twice, at length, that this app must not disclose which addresses have
# accounts -- "on an app whose whole subject is what somebody lifts". Verification puts that
# under pressure in four places. Two of them (the login form and the sign-up form) were
# already oracles before this change and are argued about in the pull request; these two are
# the ones that would have been new, and are closed.
describe 'the reset form, which answered a stranger and a member identically' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  # Without the reset_password_request_for_unverified_account override this is a 403 reading
  # "awaiting verification" where a stranger gets a 302 and a notice, which is a better
  # oracle than the one this app deliberately closed in #344.
  it 'answers an unconfirmed account the way it answers a stranger' do
    email = sign_up
    ask_for_reset("nobody-#{SecureRandom.hex}@example.com")
    stranger = [last_response.status, last_response.headers['location']]

    ask_for_reset(email)

    assert_equal stranger, [last_response.status, last_response.headers['location']]
  end

  it 'writes no reset key for an unconfirmed account' do
    email = sign_up
    ask_for_reset(email)

    assert_equal 0, DB[:account_password_reset_keys].count
  end

  it 'still works for a confirmed account' do
    email = sign_up
    confirm(confirmation_key)
    log_out
    ask_for_reset(email)

    assert_equal 1, DB[:account_password_reset_keys].count
  end
end

describe 'the resend form, which is a way to send mail to any address anyone types' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  # Rodauth answers a hit with a notice and a miss with a 401 and an error flash
  # (verify_account.rb:75-93). That is the same shape as the reset form before #344 closed it,
  # on a form whose whole purpose is to send mail -- so app.rb closes it the same way.
  it 'answers a stranger the way it answers an account waiting to be confirmed' do
    email = sign_up
    DB[:account_verification_keys].where(id: key_row(email)[:id]).update(email_last_sent: Time.now - 400)
    resend(email)
    known = [last_response.status, last_response.headers['location']]

    resend("nobody-#{SecureRandom.hex}@example.com")

    assert_equal known, [last_response.status, last_response.headers['location']]
  end

  it 'sends nothing to an address with no account' do
    @emailed = nil
    resend("nobody-#{SecureRandom.hex}@example.com")

    assert_nil @emailed
  end
end

describe 'the other two answers the resend form could give itself away with' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  it 'answers an account that is already confirmed the way it answers a stranger' do
    email = sign_up
    confirm(confirmation_key)
    log_out
    resend("nobody-#{SecureRandom.hex}@example.com")
    stranger = [last_response.status, last_response.headers['location']]

    resend(email)

    assert_equal stranger, [last_response.status, last_response.headers['location']]
  end

  # Collapsed into the same answer on purpose. If a recent send were the one case that came
  # back differently, the form would still answer "does this address have an account here",
  # just more slowly.
  it 'answers a throttled resend the way it answers a stranger' do
    email = sign_up
    resend("nobody-#{SecureRandom.hex}@example.com")
    stranger = [last_response.status, last_response.headers['location']]

    resend(email)

    assert_equal stranger, [last_response.status, last_response.headers['location']]
  end

  # The one sentence on the page has to stay true when nothing was sent, which is most of the
  # time now that every miss is answered the same way.
  it 'promises a link only if there is an account, the way the reset page does' do
    get '/verify-account-resend'

    assert last_response.ok?
    assert_includes last_response.body, 'Confirm your address'
  end
end

describe 'signing up again with an address already waiting to be confirmed' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  before { @email = sign_up }

  it 'does not make a second account' do
    sign_up(@email)

    assert_equal 1, DB[:accounts].where(email: @email).count
  end

  # #345's refusal named the way out rather than only the problem, and this keeps that
  # property under the new flow: the way out of a second sign-up on an unconfirmed address is
  # another link, not "log in instead", because logging in is exactly what does not work yet.
  it 'offers another link rather than telling them to log in' do
    sign_up(@email)

    assert_includes last_response.body, 'verify-account-resend-form'
  end
end

describe 'what the confirmation email says' do
  before { @body = Tectonic.new({}).verify_account_body('https://tectonicplates.app/verify-account?key=7_abc') }

  it 'carries the link' do
    assert_includes @body, 'https://tectonicplates.app/verify-account?key=7_abc'
  end

  # Most of the people who receive one of these never asked for it -- that is the whole
  # premise of the feature -- so the message has to be written for them too.
  it 'tells somebody who did not ask for it that there is nothing to do' do
    assert_includes @body, 'not you'
    assert_includes @body, 'nothing to do'
  end

  # It does not promise an expiry, because migrate/051 gives the key no deadline. The reset
  # email says "24 hours" and can, because that table has one.
  it 'does not claim the link expires' do
    refute_match(/expires|hours/, @body)
  end
end

describe 'the table the key lives in' do
  # requested_at belongs to verify_account_grace_period, which is deliberately not enabled --
  # a grace period would let an unconfirmed account authorise an MCP client during the window.
  # The column is here so that turning the grace period on later is a configuration change
  # rather than a second migration, and it is pinned so it is not tidied away as unused.
  it 'carries the column a grace period would need, though nothing enables one' do
    assert_includes DB.schema(:account_verification_keys).map(&:first), :requested_at
  end

  it 'holds one row per account, replaced rather than accumulated' do
    schema = DB.schema(:account_verification_keys).to_h

    assert schema[:id][:primary_key]
  end
end

