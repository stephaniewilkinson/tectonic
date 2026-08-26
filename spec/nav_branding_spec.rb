# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'
require 'bcrypt'
require 'securerandom'

# The nav in the brand face. The links were meant to be set in Blonde Sans and never were,
# at any width: styles.css hangs that face off the class token `text-xl`, the nav writes
# `sm:text-xl`, and a class selector matches whole tokens, so the rule reached nothing in
# the nav on a phone or on a desktop. Nothing moves when this is wrong -- the page renders,
# the row still fits, every other spec passes, and the only symptom is the wrong
# letterforms on somebody's screen -- so the class is asserted against the markup rather
# than looked at, and the files the face is actually delivered in are asserted to still
# come back.
module NavBranding
  def app = Tectonic.app

  # Scoped to the nav element rather than the page. `brand` is free to be used elsewhere
  # later, and this must not start passing because something else grew one.
  def nav_links
    last_response.body[%r{<nav\b.*?</nav>}m].to_s.scan(/<a\b[^>]*>/)
  end

  def classes_of(link) = link[/\sclass="([^"]*)"/, 1].to_s.split

  def wordmark = nav_links.find { |link| link.include?('href="/"') }

  # Comments stripped, because the comments in styles.css name the selectors they are
  # about and a spec that reads selectors would count those too.
  def stylesheet
    get '/assets/css/styles.css'
    last_response.body.gsub(%r{/\*.*?\*/}m, '')
  end

  def sign_in
    email = "#{SecureRandom.hex}@example.com"
    DB[:accounts].insert(email:, password_hash: BCrypt::Password.create('pw12345678'), created_on: Time.now)
    get '/login'
    csrf = last_response.body[/name="_csrf"[^>]*value="([^"]*)"/, 1]
    post '/login', { login: email, password: 'pw12345678', '_csrf' => csrf }
  end

  def assert_brand_on_every_link(count)
    assert_equal count, nav_links.length
    nav_links.each { |link| assert_includes classes_of(link), 'brand', "no brand class on #{link}" }
  end
end

describe 'the nav a signed-in account sees' do
  include Rack::Test::Methods
  include NavBranding

  before do
    sign_in
    get '/workouts'
  end

  it 'names the brand face on every one of the eight links' do
    assert_brand_on_every_link 8
  end

  # The face is named on the link now, so the size utilities no longer carry it and are
  # free to change. They are pinned anyway: the row was tuned around these two, and a
  # spec that only knew about `brand` would let the tuning go without saying so.
  it 'leaves the sizes the row was tuned around alone' do
    nav_links.each do |link|
      assert_includes classes_of(link), 'text-base'
      assert_includes classes_of(link), 'sm:text-xl'
    end
  end
end

describe 'the nav a visitor sees' do
  include Rack::Test::Methods
  include NavBranding

  before { get '/welcome' }

  it 'names the brand face on the wordmark and both account links' do
    assert_brand_on_every_link 3
  end

  # Blonde Serif is the front page's voice, set at 72px and up on the headline below this
  # nav. The wordmark sits in a 16px row on a phone, where a serif display face reads as
  # smaller rather than as more important, so it takes the same sans as the links beside
  # it and goes on being set apart by the darker text and the solid underline it already
  # had. Asserted so that the choice is a decision on the record and not a leftover.
  it 'gives the wordmark the same sans as the links and not the front page serif' do
    refute_includes classes_of(wordmark), 'serif'
    assert_includes classes_of(wordmark), 'brand'
    assert_includes classes_of(wordmark), 'text-gray-900'
  end
end

describe 'the stylesheet behind the brand class' do
  include Rack::Test::Methods
  include NavBranding

  it 'defines .brand as Blonde Sans' do
    assert_match(/\.brand\s*\{[^}]*font-family:\s*"?Blonde Sans"?/, stylesheet)
  end

  # This rule was left additive when `brand` was added, with the size utilities still in
  # it, and the trap they set went off twice more on pages that are not the nav. They are
  # gone now: a heading takes the face, `brand` takes the face, and being 24px takes
  # nothing. Asserted as an absence because that is the shape of the bug -- putting
  # `.text-2xl` back would re-brand a column of weights and break no other spec.
  it 'hangs Blonde Sans off the headings and off no size utility' do
    rule = stylesheet.split('}').find { |block| block.match?(/h1.*font-family:\s*"?Blonde Sans"?;?\z/m) }

    refute_nil rule, 'no heading rule names Blonde Sans'

    %w[h1 h2 h3 h4 h5 h6].each { |selector| assert_includes rule, selector }
    refute_match(/\.text-/, rule)
  end
end

describe 'the files the brand face is delivered in' do
  include Rack::Test::Methods
  include NavBranding

  # Naming a family in CSS is half of it. If /fonts/ stops answering, the nav falls back
  # to the generic sans and `brand` becomes a class that does nothing, which is the same
  # invisible failure this whole file exists to catch. Every URL the stylesheet asks for
  # is fetched, so a renamed or deleted file fails here rather than on a phone.
  it 'serves every font file styles.css asks for' do
    # Quotes optional: the build is minified, and a minifier drops them from a url().
    urls = stylesheet.scan(/url\(\s*"?([^)"]+)"?\s*\)/).flatten.map { |url| url.split(/[?#]/).first }.uniq

    refute_empty urls
    urls.each do |url|
      get url

      assert_equal 200, last_response.status, "#{url} is named in styles.css but is not served"
      assert_operator last_response.headers['Content-Length'].to_i, :>, 0
    end
  end

  it 'declares both faces in the format a current browser will pick' do
    %w[sans serif].each do |face|
      assert_match(%r{url\(\s*"?/fonts/blonde_#{face}-webfont\.woff2"?\s*\)\s*format\(\s*"woff2"\s*\)}, stylesheet)
    end
  end
end

