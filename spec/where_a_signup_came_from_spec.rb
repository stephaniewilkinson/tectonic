# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'confirming_the_address_spec' # Confirming#sign_up; idempotent require
require_relative '../lib/tectonic/signup_report'
require 'securerandom'

# Where an account arrived from, recorded at sign-up. #691.
module FirstTouchVisits
  include RouteOwnership
  include Confirming

  HTML = { 'HTTP_ACCEPT' => 'text/html,application/xhtml+xml' }.freeze

  def visit(path, referrer: nil)
    get path, {}, referrer ? HTML.merge('HTTP_REFERER' => referrer) : HTML
  end

  def recorded(email)
    DB[:accounts].where(email:).first.values_at(:signup_ref, :signup_referrer_host, :signup_landing_path)
  end
end

describe 'where a signup came from, recorded' do
  include Rack::Test::Methods
  include FirstTouchVisits

  def app = Tectonic.app

  it 'keeps the tag, the referring host and the first page, and nothing of the referrer but its host' do
    visit '/welcome?ref=R-Weightroom', referrer: 'https://www.reddit.com/r/weightroom/comments/abc/my_block?x=1'

    assert_equal ['r-weightroom', 'www.reddit.com', '/welcome'], recorded(sign_up)
  end

  it 'reads utm_source the same way, which is what ChatGPT puts on the links it cites' do
    visit '/docs?utm_source=chatgpt.com'

    assert_equal 'chatgpt.com', recorded(sign_up).first
  end
end

describe 'where a signup came from, when there is more than one page' do
  include Rack::Test::Methods
  include FirstTouchVisits

  def app = Tectonic.app

  # The first page is the one the channel delivered them to; what they clicked afterwards is
  # this site's own navigation and must not overwrite it.
  it 'keeps the first page, not the last' do
    visit '/docs?ref=hn', referrer: 'https://news.ycombinator.com/item?id=1'
    visit '/welcome?ref=elsewhere', referrer: 'https://example.org/'

    assert_equal ['hn', 'news.ycombinator.com', '/docs'], recorded(sign_up)
  end

  it 'records a visit that brought nothing with it as a first page and no source' do
    visit '/welcome'

    assert_equal [nil, nil, '/welcome'], recorded(sign_up)
  end

  it "notes the sign-up page itself when that is somebody's first page" do
    visit '/create-account'

    assert_equal [nil, nil, '/create-account'], recorded(sign_up)
  end

  # OAuth clients and assistants fetch metadata as JSON; they are not visitors and must not
  # be handed a session for it.
  it 'notes nothing for a request that does not ask for a page' do
    get '/welcome?ref=robot', {}, { 'HTTP_ACCEPT' => 'application/json' }
    visit '/welcome'

    assert_nil recorded(sign_up).first
  end
end

describe 'where a signup came from, reported' do
  def account(created_at: Time.utc(2026, 11, 4, 12), **touch)
    DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x', created_at:, **touch)
  end

  def sources = Tectonic::SignupReport.sources.to_h { |_, from, count, _| [from, count] }

  it 'sorts referrers into channels, lets a tag win, and keeps old accounts apart' do
    account(signup_landing_path: '/welcome', signup_referrer_host: 'chatgpt.com')
    account(signup_landing_path: '/welcome', signup_referrer_host: 'www.reddit.com')
    account(signup_landing_path: '/docs', signup_referrer_host: 'www.reddit.com', signup_ref: 'r-weightroom')
    account(signup_landing_path: '/welcome', signup_referrer_host: 'www.google.com')
    account(signup_landing_path: '/welcome', signup_referrer_host: 'blog.example.org')
    account(signup_landing_path: '/welcome')
    account

    assert_equal({ 'assistant' => 1, 'reddit' => 1, 'r-weightroom' => 1, 'search' => 1, 'other site' => 1,
                   'none' => 1, 'not recorded' => 1 }, sources)
  end

  it 'lists the raw referring hosts, so a new one is never hidden under "other site"' do
    2.times { account(signup_landing_path: '/welcome', signup_referrer_host: 'blog.example.org') }
    account(signup_landing_path: '/welcome', signup_referrer_host: 'www.google.com')

    assert_equal [['blog.example.org', 2], ['www.google.com', 1]], Tectonic::SignupReport.hosts
    assert_match(/^blog\.example\.org\s+2$/, Tectonic::SignupReport.format_hosts(Tectonic::SignupReport.hosts))
  end
end

