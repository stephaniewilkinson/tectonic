# frozen_string_literal: true

require_relative 'spec_helper'
require 'rack/test'

# The connector has documentation. #359.
#
# /docs returned 404, and both directory submissions require a public documentation URL before
# they will accept anything, so it blocked the two listing tickets as much as the tool
# annotations did.
#
# assets/robots.txt predicted this page in its own closing comment -- "worth adding the day
# there is a public page nothing links to; documentation for the connector is the likely first
# one" -- which is why the Sitemap line and the Allow entry land with it.
module ConnectorDocs
  def app = Tectonic.app

  def docs
    get '/docs'
    last_response.body
  end

  def robots
    get '/robots.txt'
    last_response.body
  end
end

describe 'the documentation page' do
  include Rack::Test::Methods
  include ConnectorDocs

  # Public and unauthenticated, because it is what a directory submission points at and what
  # somebody reads before deciding whether to connect an app to their assistant -- both of
  # which happen before there is an account to sign in to.
  it 'is served to somebody with no account' do
    get '/docs'

    assert_equal 200, last_response.status
  end

  # The one thing on the page that has to be exactly right. Built from the same value the
  # discovery document advertises rather than written out, so a page naming the endpoint cannot
  # drift from the endpoint.
  it 'names the connector address' do
    assert_includes docs, Tectonic::MCP::Config.endpoint_path
  end

  # Until a directory listing exists this link is the whole of the distribution: it opens
  # Claude's add-connector dialog prefilled, needs no listing and no review, and works signed
  # out.
  it 'offers the one-click add link, with the endpoint in it' do
    assert_match(%r{https://claude\.ai/customize/connectors\?modal=add-custom-connector}, docs)
    assert_includes docs, CGI.escape(Tectonic.new({}).send(:mcp_endpoint_url))
  end

  # The half a reader deciding whether to connect an app to an assistant actually needs. A page
  # that only lists capabilities answers the wrong question.
  it 'says what the connector will not do as well as what it will' do
    assert_includes docs, 'What it will not do'
    assert_includes docs, 'never reaches another account'
  end

  it 'says how to revoke it, and where' do
    assert_includes docs, '/connections'
  end
end

# Written against the code rather than from memory. A first draft of this page said the audit
# trail records field names and never values, which is true of the crash reports and not of the
# log -- McpAuditLog.record stores the whole argument hash, which is the right design for an
# audit trail and the wrong thing to claim the opposite of on a public page.
describe 'what the page says is stored' do
  include Rack::Test::Methods
  include ConnectorDocs

  it 'does not claim the audit trail throws the values away' do
    refute_match(/audit trail.{0,80}never their values/m, docs)
  end

  it 'says the crash reports do, which is the half that is true' do
    assert_match(/error monitoring carries the names/, docs)
  end

  # #346 wrote the terms and deliberately did not publish them: they sit in legal/ with no
  # route and no link, because section 6 is waiting on a lawyer's read. A documentation page
  # linking to them would be a 404 on the one page a directory submission points at.
  it 'does not link to terms that are not served' do
    refute_includes docs, 'href="/terms"'
    refute_includes docs, 'href="/privacy"'
  end
end

describe 'robots.txt' do
  include Rack::Test::Methods
  include ConnectorDocs

  it 'lets a crawler have the new page' do
    assert_includes robots, 'Allow: /docs'
  end

  # The line this file has been holding open since it was written.
  it 'names a sitemap now that there is one' do
    assert_match(/^Sitemap: \S+sitemap\.xml$/, robots)
  end

  # A Sitemap line pointing at a 404 is worse than no line at all, because a crawler believes
  # it and comes back for it.
  it 'names a sitemap that is actually served' do
    get URI.parse(robots[/^Sitemap: (\S+)$/, 1]).path

    assert_equal 200, last_response.status
  end
end

describe 'the sitemap' do
  include Rack::Test::Methods
  include ConnectorDocs

  before { get '/sitemap.xml' }

  it 'lists the new page' do
    assert_includes last_response.body, '/docs</loc>'
  end

  # Everything else is behind a login and is Disallow-ed in robots.txt. Listing any of it would
  # be asking a crawler to fetch pages that answer 302.
  it 'lists nothing that needs an account' do
    %w[/workouts /exercises /volume /settings /connections].each do |path|
      refute_includes last_response.body, "#{path}</loc>"
    end
  end
end

# The metadata was pointing at the one term this domain cannot win. #342 found that search
# returns no organic results for the literal string tectonicplates.app, and that "tectonic"
# belongs to a Minecraft mod -- while the title and description contained none of Claude,
# ChatGPT, MCP, connector or AI, and the visible headline has said "Ask Claude what to lift"
# since #269.
describe 'what the pages say they are' do
  include Rack::Test::Methods
  include ConnectorDocs

  it 'names the connector in the default title rather than only the app' do
    get '/welcome'

    assert_match(%r{<title>[^<]*Claude[^<]*</title>}, last_response.body)
  end

  it 'names what is actually searched for in the description' do
    get '/welcome'

    description = last_response.body[/<meta name="description" content="([^"]*)"/, 1]

    assert_includes description, 'MCP'
    assert_includes description, 'barbell'
  end

  # #358 is explicit that the competitor's line -- "first strength app Claude can write to" --
  # is taken, timestamped two months earlier, and on a product that is free. Claiming it
  # invites the comparison on the one axis where the answer is "and theirs is free".
  it 'does not claim to be the first of anything' do
    get '/welcome'

    refute_match(/first strength app/i, last_response.body)
  end

  # A page may say what it is; every page that does not gets the app's own description, which
  # is the right fallback for forty pages behind a login that no crawler will ever see.
  it 'lets a page say what it is instead' do
    get '/docs'

    assert_match(%r{<title>Connect tectonic plates to Claude or ChatGPT</title>}, last_response.body)
  end
end

# A page nobody can find from the site is a bad page whatever a crawler thinks.
describe 'finding the page at all' do
  include Rack::Test::Methods
  include ConnectorDocs

  it 'is linked from the front page' do
    get '/welcome'

    assert_includes last_response.body, 'href="/docs"'
  end

  it 'is linked from the about page' do
    get '/about'

    assert_includes last_response.body, 'href="/docs"'
  end
end

