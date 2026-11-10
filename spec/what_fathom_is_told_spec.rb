# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'confirming_the_address_spec' # Confirming#sign_up; idempotent require
require_relative 'connecting_before_signing_in_spec' # its OAuth and signed-out helpers

# The events the weekly Fathom email shows. #687; views/_fathom_events.erb.
describe 'what Fathom is told about a new account' do
  include Rack::Test::Methods
  include RouteOwnership
  include Confirming

  def app = Tectonic.app

  it 'counts the account once, on the page after sign-up, and not on a reload' do
    sign_up
    get '/check-your-email'
    assert_includes last_response.body, 'track("account_created")'

    get '/check-your-email'
    refute_includes last_response.body, 'track("account_created")'
  end
end

describe 'what Fathom is told about a connection that did not finish' do
  include Rack::Test::Methods
  include OAuthFlow
  include Confirming
  include ConnectingSignedOut

  it 'says so on /start, while the note there says so' do
    consent_page(register_client)
    sign_up
    key = confirmation_key
    clear_cookies
    confirm(key)
    land

    assert_equal '/start', last_request.path
    assert_includes last_response.body, 'track("connect_unfinished")'
  end
end

# Fathom names cannot be deleted, and some strings in this app -- an OAuth client's name above
# all -- are chosen by somebody else. So every name is typed into the markup, never computed.
describe 'the names Fathom is sent' do
  it 'are literals in every view that names one' do
    named = Dir[File.expand_path('../views/**/*.erb', __dir__)].flat_map do |view|
      File.read(view).scan(/data-fathom-(?:click|submit)="([^"]*)"/).flatten
    end

    assert_equal %w[add_to_claude_clicked connector_url_copied workout_logged], named.uniq.sort
    named.each { |name| assert_match(/\A[a-z_]+\z/, name) }
  end
end

