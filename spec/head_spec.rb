# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# What the document head tells the rest of the internet about this app: which domain it
# lives at, what a share card should fetch, and what a browser should draw in the tab.
#
# All three failed quietly. The share card named tectonic.onrender.com, the subdomain the
# app lived at before tectonicplates.app, so every platform cached an image from a domain
# the app has moved off -- and a card is fetched once and kept, which means the person
# sharing sees the old good card and only the recipient sees the broken one. There was no
# canonical link, so the two domains were two sites serving one set of pages. And there
# was no icon of any kind, which is the one of the three that everybody sees.
module Head
  # The old Render subdomain. It still resolves and render.yaml still allows it as a
  # Host, which is what let it survive review in a share card: it works today.
  RETIRED_DOMAIN = 'tectonic.onrender.com'
  ORIGIN = 'https://tectonicplates.app'
  # What the head links, and the content type each has to come back as. A head naming a
  # file the app does not serve is worse than a head naming nothing.
  ICONS = { '/favicon.ico' => 'image/vnd.microsoft.icon', '/icon.svg' => 'image/svg+xml',
            '/apple-touch-icon.png' => 'image/png' }.freeze
  # Most of this app is behind a login, so robots.txt protects nothing -- a crawler that
  # ignores it gets a 302 to the login form. What it saves is the request.
  PRIVATE = %w[/start /workouts /exercises /volume /programs /settings /equipment
               /connections /authorize /token].freeze
  PUBLIC = %w[/welcome /about /login /create-account].freeze

  def app
    Tectonic.app
  end

  def head_of(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not render"
    last_response.body[%r{<head>.*?</head>}m]
  end

  # Comments stripped, because the layout's own comments name the retired domain: saying
  # why a card must not point at it means saying which one it was, and a spec that forbade
  # the word would forbid the explanation with it.
  def each_view_without_comments
    Dir[File.expand_path('../views/**/*.erb', __dir__)].each do |view|
      yield File.basename(view), File.read(view).gsub(/<%#.*?%>/m, '').gsub(/<!--.*?-->/m, '')
    end
  end
end

describe 'the domain the head names' do
  include Rack::Test::Methods
  include Head

  it 'points every share card at the domain the app is actually served from' do
    head = head_of('/welcome')

    refute_includes head, Head::RETIRED_DOMAIN
    assert_includes head, "#{Head::ORIGIN}/img/screenshot.jpeg"
  end

  # Across the whole tree rather than one page, because the failure was one literal
  # copied into four meta tags and a fifth would have been just as invisible.
  it 'has no view left naming the retired subdomain outside a comment' do
    each_view_without_comments do |name, markup|
      refute_includes markup, Head::RETIRED_DOMAIN, "#{name} still names it"
    end
  end

  it 'gives each page a canonical URL of its own' do
    assert_includes head_of('/welcome'), %(<link rel="canonical" href="#{Head::ORIGIN}/welcome">)
    assert_includes head_of('/about'), %(<link rel="canonical" href="#{Head::ORIGIN}/about">)
  end

  # slash_path_empty serves /about and /about/ as one page. A canonical that repeated back
  # whichever was asked for would be two answers to the question it exists to settle.
  it 'answers the same canonical URL with or without a trailing slash' do
    assert_includes head_of('/about/'), %(<link rel="canonical" href="#{Head::ORIGIN}/about">)
  end
end

describe 'the card a shared link draws' do
  include Rack::Test::Methods
  include Head

  before { @head = head_of('/welcome') }

  it 'describes its image to a reader who cannot see it' do
    assert_match(/<meta property="og:image:alt" content="[^"]{20,}">/, @head)
    assert_match(/<meta name="twitter:image:alt" content="[^"]{20,}">/, @head)
  end

  it 'attributes itself to somebody' do
    assert_includes @head, '<meta property="og:site_name" content="tectonic plates">'
    assert_includes @head, '<meta name="twitter:site" content="@stephanieblack">'
  end
end

describe 'the mark a browser draws' do
  include Rack::Test::Methods
  include Head

  it 'names an icon for each of the three things that ask for one' do
    head = head_of('/welcome')

    assert_includes head, '<link rel="icon" href="/favicon.ico" sizes="32x32">'
    assert_includes head, '<link rel="icon" href="/icon.svg" type="image/svg+xml">'
    assert_includes head, '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
    assert_includes head, '<meta name="theme-color" content="#075985">'
  end

  # Followed rather than only read, and /favicon.ico among them because a browser asks
  # for that one whether or not anything links to it.
  it 'serves all three' do
    Head::ICONS.each do |path, type|
      get path

      assert_equal 200, last_response.status, "#{path} is linked but not served"
      assert_equal type, last_response.headers['content-type'], "#{path} came back as the wrong type"
      refute_predicate last_response.body.bytesize, :zero?
    end
  end
end

describe 'robots.txt' do
  include Rack::Test::Methods
  include Head

  before do
    get '/robots.txt'

    @body = last_response.body
  end

  it 'is served' do
    assert_equal 200, last_response.status
  end

  # A route added later without a line here is how this goes stale, so the list is
  # asserted rather than the file merely existing.
  it 'keeps crawlers off every page that needs a login' do
    Head::PRIVATE.each { |path| assert_includes @body, "Disallow: #{path}", "#{path} needs a login and is not named" }
  end

  it 'lets the four public pages through' do
    Head::PUBLIC.each { |path| assert_includes @body, "Allow: #{path}" }
  end

  # #254 called the sitemap optional at four pages, and worth deciding rather than
  # forgetting. It was decided against, and this is where that is written down.
  it 'names no sitemap, which is the decision and not an omission' do
    refute_includes @body, 'Sitemap:'
    assert_includes @body, 'No Sitemap line, deliberately'
  end
end

