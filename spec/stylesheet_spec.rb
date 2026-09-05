# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# The stylesheet is a stylesheet again.
#
# It was `<script src="https://cdn.tailwindcss.com">`, the Play CDN, which ships a compiler
# to the browser and generates the CSS at runtime -- something Tailwind's own documentation
# says is not for production. With JavaScript off there was therefore no CSS at all: not
# degraded styling, none, because the stylesheet was a script. And it was a third party on
# every page, including the consent screen, where one tap hands an API client the account.
module Stylesheet
  ROOT = File.expand_path('..', __dir__)
  CDN = 'cdn.tailwindcss.com'

  def app = Tectonic.app

  def layouts
    Dir[File.join(ROOT, 'views', '*layout.erb')]
  end
end

describe 'the layouts' do
  include Rack::Test::Methods
  include Stylesheet

  it 'load no compiler from a CDN' do
    refute_empty layouts

    layouts.each do |path|
      refute_includes File.read(path), Stylesheet::CDN, "#{File.basename(path)} still loads the Play CDN"
    end
  end

  # The whole of what "no CSS without JavaScript" meant: the styles arrive over a link
  # element, which a browser fetches whether or not it runs scripts.
  it 'ask for the styles with a link rather than a script' do
    get '/login'

    assert_match(/<link[^>]*rel="stylesheet"[^>]*href="[^"]*styles\.css/, last_response.body)
  end
end

describe 'the stylesheet the app serves' do
  include Rack::Test::Methods
  include Stylesheet

  before { get '/assets/css/styles.css' }

  it 'is served as CSS' do
    assert_equal 200, last_response.status
    assert_includes last_response.headers['content-type'], 'text/css'
  end

  # A compiled Tailwind build, not the hand-written source. If the build were skipped the
  # file would still be served and still be valid CSS -- it would simply have no utilities
  # in it, and every page would render as an unstyled document, which is the failure this
  # whole change is about.
  it 'carries the utilities the views are written in' do
    %w[.bg-lime-500 .rounded-md .text-gray-900 .flex].each do |utility|
      assert_includes last_response.body, utility, "the build is missing #{utility}"
    end
  end

  # These are built in Ruby -- app.rb's button_style and rpe_style, calendar.rb's STYLES --
  # and appear in no template at all, so a content glob covering only views/ would purge
  # them and leave the session screen and the calendar unstyled in production.
  it 'carries the classes that only Ruby names' do
    %w[.bg-lime-100 .focus-visible\\:outline-sky-800 .focus\\:ring-sky-800 .bg-sky-800].each do |utility|
      assert_includes last_response.body, utility, "#{utility} was purged; check tailwind.config.js content"
    end
  end

  # It also has to keep carrying what this app wrote itself, which is compiled through the
  # same file rather than served as a second stylesheet.
  it 'still carries the app\'s own rules' do
    assert_includes last_response.body, 'Blonde Sans'
    assert_includes last_response.body, 'appearance:textfield'
  end
end

# The consent screen ran exactly one script and it was the CDN. With the stylesheet a
# stylesheet, it runs none, so its policy can say so -- which is the security half of #142.
describe 'the consent screen policy' do
  it 'no longer has to allow a script source at all' do
    refute_includes Tectonic::CONSENT_SECURITY_POLICY, Stylesheet::CDN
    refute_includes Tectonic::CONSENT_SECURITY_POLICY, 'script-src'
    assert_includes Tectonic::CONSENT_SECURITY_POLICY, "default-src 'none'"
  end
end

