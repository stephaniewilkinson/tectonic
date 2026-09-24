# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its login; idempotent require

# #629. /start is the first page a new account sees, and its middle card, "Write a block", went
# to /programs -- which #411 turned into a redirect to an empty workouts list. It also put the
# assistant last, against what /welcome promised. It leads with the assistant now.
describe 'the page a new account starts on' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    login
    get '/start'
    @page = last_response.body
  end

  it 'leads with planning a block with an assistant' do
    assistant = @page.index('Plan your first block with your assistant')
    logging = @page.index('Or log a session you have already done')

    refute_nil assistant
    refute_nil logging
    assert_operator assistant, :<, logging
  end

  it 'sends the assistant card to where one is connected' do
    assert_includes @page, 'href="/connections"'
  end

  # A blank chat box is the next place a new lifter stops, so the card gives them a first thing
  # to say -- one that needs no training history behind it.
  it 'gives a first thing to ask for' do
    assert_includes @page, 'coming back after six weeks off'
  end

  it 'no longer offers a block editor that does not exist' do
    refute_includes @page, 'href="/programs"'
  end
end

