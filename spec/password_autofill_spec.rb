# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'securerandom'

# What the two account forms tell a password manager to do with the credential. iOS
# Keychain would not offer to save an account created here, and the markup said why: both
# password boxes on the sign-up form carried autocomplete="off", which is precisely the
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
end

describe 'the sign-in form' do
  include Rack::Test::Methods
  include AuthForm

  before { get '/login' }

  # "username" is the identifier token in the autofill vocabulary; "email" is an address
  # field, the kind a checkout asks for. A manager keys the credential to the former.
  it 'names the account identifier the way a password manager reads it' do
    assert_equal 'username', autocomplete('login')
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

  # The confirmation box takes the same token on purpose: it is what lets a manager put a
  # generated password into both boxes instead of one, leaving the form unsubmittable.
  it 'offers the new credential for saving instead of refusing it' do
    assert_equal 'new-password', autocomplete('password')
    assert_equal 'new-password', autocomplete('password-confirm')
    refute_includes last_response.body, 'autocomplete="off"'
  end

  # A credential saved here is offered back at sign-in only if both forms name the
  # identifier the same way, so the two tokens are asserted against each other.
  it 'names the identifier the same way the sign-in form does' do
    assert_equal 'username', autocomplete('login')
    assert_equal 'email', autocomplete('login-confirm')
  end

  it 'writes one id per field and no id twice' do
    assert_one_id_each 'login', 'login-confirm', 'password', 'password-confirm'
    assert_labels_resolve
  end
end

describe 'the names an account form posts under' do
  include Rack::Test::Methods
  include AuthForm

  # The ids on these forms are ours, but the names are Rodauth's: it reads the address out
  # of a parameter called "login" and the two confirmations out of "login-confirm" and
  # "password-confirm", none of which this app overrides. Tidying an id is one careless
  # keystroke away from renaming a field, so the form is filled in from the names it
  # actually renders and Rodauth is asked whether it recognised them.
  it 'creates an account from exactly the fields it renders' do
    get '/create-account'
    email = "#{SecureRandom.hex}@example.com"
    names = inputs.filter_map { |tag| tag[/\sname="([^"]*)"/, 1] } - ['_csrf']
    params = names.to_h { |name| [name, name.start_with?('login') ? email : 'pw12345678'] }
    params['_csrf'] = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]

    post '/create-account', params

    assert_equal 1, DB[:accounts].where(email:).count
  end
end

