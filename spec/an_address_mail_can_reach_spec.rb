# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'confirming_the_address_spec'
require 'securerandom'

# Resend refused a confirmation email in production with a 422: "Invalid `to` field". Since
# #575 the confirmation is the only way into an account, so sign-up had taken an address it
# could never finish, and sent the person off to wait for an email that was never coming.
# Rodauth's default pattern is only "something@something.something"; the form's
# `type="email"` is a browser's courtesy, and the JSON route has no browser at all.
describe 'an address sign-up cannot send to' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  [
    'two..dots@example.com',
    'trailing.dot@example.com.',
    '.leading@example.com',
    'doubled@example..com',
    '"quoted"@example.com',
    '<angled@example.com>',
    "tab\t@example.com",
    'one-letter@example.c'
  ].each do |address|
    it "is refused on the form rather than mailed: #{address.inspect}" do
      @emailed = nil
      sign_up(address)

      assert_equal 422, last_response.status
      assert_includes last_response.body, 'not an address mail can be delivered to'
      assert_nil @emailed
      assert_equal 0, DB[:accounts].where(email: address).count
    end
  end
end

describe 'an address sign-up can send to' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  %w[first.last+lifting@sub.example.co.uk o'neil@example.io x@xn--80ak6aa92e.com].each do |shape|
    it "is taken: #{shape}" do
      address = "#{SecureRandom.hex(4)}#{shape}"
      sign_up(address)

      assert_equal address, @emailed.first
      assert_equal 1, DB[:accounts].where(email: address).count
    end
  end

  # A pasted address often carries a space, and from a phone a non-breaking one. It is not
  # part of the address, and mailing it with the space attached is the same 422.
  it 'is stored and mailed without the space pasted around it' do
    address = "#{SecureRandom.hex}@example.com"
    sign_up(" #{address} ")

    assert_equal address, @emailed.first
    assert_equal 1, DB[:accounts].where(email: address).count
  end
end

