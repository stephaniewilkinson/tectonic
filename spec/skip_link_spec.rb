# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# #334: every page opens with the same eight nav links, so a keyboard or screen-reader
# user stepped through all of them before reaching the page itself, on every load. The
# remedy only works if the skip link is the first thing focus can land on and its
# target actually exists -- both of which are exactly the kind of fact a refactor of
# the layout would silently lose.
describe 'the skip link' do
  include Rack::Test::Methods

  def app
    Tectonic.app
  end

  before do
    get '/welcome'
    @body = last_response.body
  end

  it 'is the first thing in the body, ahead of the nav' do
    skip_link = @body.index('Skip to content')

    refute_nil skip_link, 'no skip link on the page'
    assert_operator skip_link, :<, @body.index('<nav')
  end

  it 'points at a target that exists' do
    target = @body[/<a href="#([\w-]+)"[^>]*>Skip to content/, 1]

    refute_nil target, 'the skip link is not an anchor to a fragment'
    assert_includes @body, %(id="#{target}")
  end
end

