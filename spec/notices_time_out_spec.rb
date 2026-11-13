# frozen_string_literal: true

# #717. "You have been logged in" stayed above the page for as long as it was open. A
# confirmation now fades; an instruction to go and read an email does not.

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # login, make_account, token_from; idempotent require

describe 'a notice that has said its piece' do
  include Rack::Test::Methods
  include RouteOwnership

  def notice_tag = last_response.body[/<div role="status"[^>]*>/].to_s

  it 'fades after signing in' do
    login
    follow_redirect! while last_response.redirect?

    assert_includes notice_tag, 'data-fades'
  end

  it 'stays when it says a reset link is on its way' do
    email, = make_account
    get '/reset-password-request'
    post '/reset-password-request', { login: email, '_csrf' => token_from(last_response.body) }
    follow_redirect! while last_response.redirect?

    refute_empty notice_tag
    refute_includes notice_tag, 'data-fades'
  end
end

