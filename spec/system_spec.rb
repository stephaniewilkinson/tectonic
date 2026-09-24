# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

describe Tectonic do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include Rack::Test::Methods

  password = SecureRandom.hex
  email = "#{SecureRandom.hex}@gmail.com"

  let :app do
    Tectonic
  end

  it 'responds to root' do
    visit '/'
    assert current_path == '/welcome'
  end

  it 'responds to /about' do
    get '/about'
    assert last_response.ok?
    assert_includes last_response.body, 'stephanie'
  end

  # The sign-in page carried a "Forgot password?" link at href="#" from the day it was
  # written. reset_password is not in the enable list and this app configures no mailer, so
  # there was nothing behind it and nothing to put behind it. It is pinned rather than
  # trusted because a dead link and a live one are the same shape on the page, and the
  # cheapest way to make this promise again is to paste the markup back.
  it 'promises no way back into an account that it cannot deliver' do
    get '/login'

    assert last_response.ok?
    refute_includes last_response.body, 'href="#"'
  end

  # The sign-up walk, with the email in the middle of it that #575 put there, driven the way
  # a person walks it: fill the form, read the link out of the message that was sent, open it,
  # press the button.
  #
  # The mailer is stubbed rather than left to log, because the link is the only thing in this
  # flow the test cannot construct honestly -- and because reading it out of the message is
  # what proves the message carries a usable one. The stub is in place across the click alone,
  # which is enough: Capybara's `click_on` does not return until the response has been served,
  # and that response is served on a Puma thread inside this process, so the send has already
  # happened by the time the block ends.
  #
  # The link is visited by path rather than by URL. Capybara's server binds an ephemeral port
  # and the app builds its links from the request it was serving, so the host in the message
  # is right for the request that made it and is not worth re-resolving here.
  def confirm_the_address_of(mail, pass)
    sent = nil
    Tectonic::Mailer.stub(:deliver, ->(to:, text:, **) { sent = text if to == mail }) do
      visit '/'
      click_on 'Sign up'
      fill_in 'email', with: mail
      click_on 'Sign up'
    end
    # The password is typed here and not on the form, which is the half of this walk only a
    # browser proves: the sign-up page has no box to type it into, so a `fill_in 'password'`
    # up there would raise rather than quietly go nowhere.
    visit sent[%r{/verify-account\?key=\S+}]
    fill_in 'password', with: pass
    click_on 'Save it and sign in'
  end

  it 'lets new user sign up' do
    confirm_the_address_of(email, password)
    # An account a second old lands on the first-run page, not on the calendar: a month
    # with nothing on it answers a question a brand new account has not asked yet.
    assert_includes page.body, 'Start here'
    # The calendar is still where it was, one tap away in the nav.
    click_on 'tectonic plates'
    assert_includes page.body, 'Start a new workout'
    click_on 'exit'
    assert_includes page.body, 'Log out'
    click_on 'Log out'
  end

  it 'deletes a workout in place with htmx' do
    pw = SecureRandom.hex
    mail = "#{SecureRandom.hex}@gmail.com"

    confirm_the_address_of(mail, pw)

    visit '/workouts/new'
    click_on 'Save'

    visit '/workouts'
    assert_equal 1, all('tbody tr').count

    # A full page load clears this; an htmx row swap leaves it in place, which is
    # what tells the two apart and proves the delete never navigated.
    page.execute_script('window.stayedOnPage = true')
    within(first('tbody tr')) { click_button 'Delete' }

    assert has_no_selector?('tbody tr'), 'the deleted workout should leave the list'
    assert page.evaluate_script('window.stayedOnPage === true'), 'delete should not reload the page'
    assert_equal '/workouts', current_path
  end
end

