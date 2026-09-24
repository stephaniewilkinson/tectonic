# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'securerandom'

# What the two account forms tell a password manager to do with the credential. iOS
# Keychain would not offer to save an account created here, and the markup said why: every
# password box on the sign-up form carried autocomplete="off", which is precisely the
# instruction not to save a password. These tokens are asserted rather than looked at
# because nothing on the page moves when one of them is wrong -- the form renders the
# same, submits the same and passes every other spec, and the damage only appears on
# somebody's phone. Assertions run against the bytes the server sent rather than against a
# parsed DOM: a tag carrying two id attributes is a parse error, and a browser hides it by
# keeping the first id and dropping the second.
module AuthForm
  def app
    Tectonic.app
  end

  def inputs
    last_response.body.scan(/<input\b[^>]*>/)
  end

  def field(name)
    inputs.find { |tag| tag.include?(%(name="#{name}")) }
  end

  def autocomplete(name)
    field(name)[/\sautocomplete="([^"]*)"/, 1]
  end

  def page_ids
    last_response.body.scan(/\sid="([^"]*)"/).flatten
  end

  def assert_one_id_each(*names)
    names.each { |name| assert_equal 1, field(name).scan(/\sid="/).length, "#{name} needs exactly one id" }
    assert_equal page_ids.uniq, page_ids
  end

  # An id is only worth anything here if the label still reaches the field: a manager
  # reads the label to caption what it saves, and Capybara's fill_in finds boxes this way.
  def assert_labels_resolve
    last_response.body.scan(/<label[^>]*\sfor="([^"]*)"/).flatten.each do |target|
      assert_includes page_ids, target
    end
  end

  def csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]

  # The page the emailed link leads to, which since #575 is where the password box lives.
  # Reached by signing up and following the link, because that is the only way to reach it:
  # the route refuses without a key, and Rodauth moves the key into the session on the way
  # past so the form itself carries nothing.
  def open_the_page_the_link_leads_to
    email = "#{SecureRandom.hex}@example.com"
    Tectonic::Mailer.stub(:deliver, ->(**) { true }) do
      get '/create-account'
      post '/create-account', { login: email, '_csrf' => csrf }
    end
    follow_the_key_written_for(email)
    email
  end

  def follow_the_key_written_for(email)
    row = DB[:account_verification_keys].where(id: DB[:accounts].where(email:).get(:id)).first
    get "/verify-account?key=#{row[:id]}_#{row[:key]}"
    follow_redirect! while last_response.redirect?
  end
end

describe 'the sign-in form' do
  include Rack::Test::Methods
  include AuthForm

  before { get '/login' }

  # "email" rather than "username": an account here is identified by its address and by
  # nothing else, so there is no username for a manager to key a credential to. The pair
  # of forms matters more than the token does, which is what the sign-up spec asserts.
  it 'names the account identifier the way a password manager reads it' do
    assert_equal 'email', autocomplete('login')
    assert_includes field('login'), 'type="email"'
  end

  it 'asks for the password the manager already holds' do
    assert_equal 'current-password', autocomplete('password')
  end

  it 'writes one id per field and no id twice' do
    assert_one_id_each 'login', 'password'
    assert_labels_resolve
  end
end

describe 'the sign-up form' do
  include Rack::Test::Methods
  include AuthForm

  before { get '/create-account' }

  # A credential saved here is offered back at sign-in only if both forms name the
  # identifier the same way, so the two tokens are asserted against each other.
  it 'names the identifier the same way the sign-in form does' do
    assert_equal 'email', autocomplete('login')
  end

  # Nobody types either of these twice any more. Asserting the boxes are gone is cheap
  # next to what putting one back silently costs: Rodauth stops requiring a confirmation
  # it is not shown, so a re-added box would be collected, ignored and never compared.
  it 'asks for neither the address nor the password a second time' do
    assert_nil field('login-confirm')
    assert_nil field('password-confirm')
  end

  # And since #575 it does not ask for the password a first time either. A box here would be
  # worse than useless: `create_account_set_password?` is false while verify_account is
  # enabled, so Rodauth collects the parameter and drops it -- somebody would type a password
  # that is stored nowhere and then find it does not work.
  it 'does not ask for a password at all, because there is nowhere to put one yet' do
    assert_nil field('password')
  end

  it 'writes one id per field and no id twice' do
    assert_one_id_each 'login'
    assert_labels_resolve
  end
end

# Where the autofill claims went. They were about the sign-up form until #575 moved the
# password to the page the emailed link leads to; they are the same claims about the same box
# on a different page, which is why they are moved rather than deleted. iOS Keychain refusing
# to save a credential is the failure this whole file exists for, and it does not care which
# route the box is on.
describe 'the page where the password is chosen' do
  include Rack::Test::Methods
  include AuthForm

  before { open_the_page_the_link_leads_to }

  # This token carries more weight here than it did on the sign-up form, and lands less
  # often. More, because this is now the only moment a credential is created and nothing
  # else catches a typo in it. Less, because the page is reached from an email, so it is
  # frequently open in a different browser from the one that filled the sign-up form in, or
  # on a phone -- and whichever manager would have offered to generate and keep the password
  # may simply not be there. app.rb's note on this flow takes that trade deliberately; this
  # asserts the half of it that is in our hands.
  it 'offers the new credential for saving instead of refusing it' do
    assert_equal 'new-password', autocomplete('password')
    refute_includes last_response.body, 'autocomplete="off"'
  end

  it 'asks for the password once, not twice' do
    assert_nil field('password-confirm')
  end

  it 'writes one id per field and no id twice' do
    assert_one_id_each 'password'
    assert_labels_resolve
  end

  # The other half of the move: Rodauth's own template renders a password box here only while
  # `verify_account_set_password?` is true, and this app's template renders one unconditionally.
  # If that default were ever overridden the box would stay on the page, be posted, and be
  # ignored -- a form that looks like it works and sets nothing.
  it 'sets the password from exactly the fields it renders' do
    names = inputs.filter_map { |tag| tag[/\sname="([^"]*)"/, 1] } - ['_csrf']
    params = names.to_h { |name| [name, 'chosen-here-4321'] }
    params['_csrf'] = csrf

    post '/verify-account', params

    assert_equal '/start', last_response.headers['location']
  end
end

describe 'the names an account form posts under' do
  include Rack::Test::Methods
  include AuthForm

  # The ids on these forms are ours, but the names are Rodauth's: it reads the address out
  # of a parameter called "login", which this app does not override. Tidying an id is one
  # careless keystroke away from renaming a field, so the form is filled in from the names
  # it actually renders and Rodauth is asked whether it recognised them.
  #
  # That question is now the one that matters most on this file. Removing the confirmation
  # boxes from the markup is not what removed the confirmations: Rodauth defaults to
  # demanding "login-confirm" on the post and refuses without it, so this passes only while
  # require_login_confirmation? is false in app.rb. Undo it and every sign-up in the app
  # fails here. Its sibling, require_password_confirmation?, is asserted the same way by the
  # last spec in the describe above, which now owns the password box.
  it 'creates an account from exactly the fields it renders' do
    get '/create-account'
    email = "#{SecureRandom.hex}@example.com"
    names = inputs.filter_map { |tag| tag[/\sname="([^"]*)"/, 1] } - ['_csrf']
    params = names.to_h { |name| [name, name.start_with?('login') ? email : 'pw12345678'] }
    params['_csrf'] = csrf

    Tectonic::Mailer.stub(:deliver, ->(**) { true }) { post '/create-account', params }

    assert_equal 1, DB[:accounts].where(email:).count
  end
end

