# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# The app says it is free while it is in beta. #430.
#
# Nothing on any public page said what this costs. Not "free", not a price, not a plan, not
# "beta" -- the word appeared only in code comments. So the app was not quietly free, it was
# *silent*, and a visitor had to guess. The default guess about a training app with an AI
# connector is that there is a paywall behind the button, which costs a signup at the exact
# moment somebody was about to make one. Against a competitor who is free and markets that
# (#358), saying nothing reads worse than the truth.
#
# What is asserted here is the promise rather than the wording. Copy gets edited and should not
# have to come here first; what must not quietly change is *which promise is being made* --
# free now, not free forever, and no card -- because that sentence is the disclosure any future
# price would be read against.
module FreeBeta
  # The five surfaces #430 names. The docs page and the front page carry the weight; the other
  # three are where somebody is mid-decision.
  PAGES = %w[/welcome /docs /create-account /about].freeze

  def app = Tectonic.app

  def body_of(path)
    get path

    assert_equal 200, last_response.status, "#{path} did not answer"
    last_response.body
  end
end

describe 'what the public pages say it costs' do
  include Rack::Test::Methods
  include FreeBeta

  it 'says it on every page somebody decides on' do
    FreeBeta::PAGES.each do |path|
      assert_match(/free/i, body_of(path), "#{path} says nothing about price")
    end
  end

  # The half people actually want to know. A free tier that still asks for a card is the
  # pattern this sentence is competing with.
  it 'says there is no card to enter where somebody is about to sign up' do
    %w[/welcome /create-account].each do |path|
      assert_match(/no card/i, body_of(path), "#{path} does not say whether a card is wanted")
    end
  end

  # The most valuable place on the site for it, and until #430 the least explicit: the
  # add-to-Claude box is the whole distribution mechanism until a directory listing exists, and
  # the single moment a stranger decides to hand an assistant access to an account they do not
  # have yet.
  it 'says it in the box that connects an assistant' do
    docs = body_of('/docs')
    box = docs[%r{Add it in one click.*?</div>}m]

    assert_match(/free/i, box.to_s)
  end
end

# The clause that makes the whole sentence honest. #347 has three shapes on it and no decision,
# so "free" without it would be a promise this repo has no way to keep -- and #346's research
# found that California's auto-renewal rules care about what was disclosed *before* a charge,
# not only about the charge. Whatever is on these pages now is that disclosure.
describe 'the promise being made' do
  include Rack::Test::Methods
  include FreeBeta

  it 'is qualified everywhere it is made' do
    FreeBeta::PAGES.each do |path|
      assert_match(/beta/i, body_of(path), "#{path} says free without saying while what")
    end
  end

  it 'never promises it will always be free' do
    FreeBeta::PAGES.each do |path|
      refute_match(/free forever|always free|free for life/i, body_of(path))
    end
  end

  # Somewhere has to say the second half out loud, or "while it's in beta" is a qualifier with
  # nothing behind it. /about is the page with room for it, and it promises notice rather than
  # a price, because the price is #347's and is genuinely undecided.
  it 'says once, in full, what happens if that changes' do
    assert_match(/hear about it before anything changes/i, body_of('/about'))
  end
end

# "Free" is a word people put in the query box, and a description that omits it loses the
# comparison before anybody clicks.
describe 'what a search result says it costs' do
  include Rack::Test::Methods
  include FreeBeta

  it 'is in the description a crawler reads' do
    description = body_of('/welcome')[/<meta name="description" content="([^"]*)"/, 1]

    assert_match(/free/i, description)
    assert_match(/beta/i, description)
  end

  # Two surfaces making different promises about price is the one kind of drift this particular
  # sentence must not have.
  it 'says the same thing the page does' do
    page = body_of('/welcome')
    description = page[/<meta name="description" content="([^"]*)"/, 1]

    refute_match(/free forever|always free/i, description)
    assert_match(/free/i, page.sub(%r{\A.*</head>}m, ''))
  end
end

# #326 decided no vendor is named anywhere a reader is being told what this app is, and there
# is already a spec on /welcome enforcing it. The price copy does not need a vendor name, and
# this is what stops it acquiring one the next time the sentence is edited.
describe 'the price copy against the vendor rule' do
  include Rack::Test::Methods
  include FreeBeta

  it 'names no vendor on the front page' do
    visible = body_of('/welcome').sub(%r{\A.*</head>}m, '')

    refute_match(/\bClaude\b/, visible)
    refute_match(/\bChatGPT\b/, visible)
  end
end

