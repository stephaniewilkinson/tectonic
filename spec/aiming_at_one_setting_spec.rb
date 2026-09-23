# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'connections_spec'     # and the registered client + live grant an assistant is
# The budget field is bounded by a constant that lives with the MCP tools, so a run of this
# file on its own reaches it before anything else has loaded one. Same require, and the same
# reason, as a_budget_on_the_lifter_spec.
require_relative '../lib/tectonic/mcp'

# Reaching one setting without scrolling past the other four. #529.
#
# The issue asks for submenus under the settings dropdown and there is no dropdown: the top
# bar is a flat row of links and `settings` is one of them. Asked what was actually wanted,
# the answer was the page and not the bar -- group what is already on /settings under five
# names, in a stated order, and leave the nav exactly as it is.
#
# What is asserted here is the decision as much as the wiring, because the decision is the
# part a later change could undo with nothing going red. Four claims:
#
#   the five sections exist, are named the way they were asked for, and are in that order
#   each one can be aimed at directly, and every aim lands on something
#   the top bar is untouched, `assistants` included
#   no form was moved into another, and a save still comes back to what it saved
#
# And the fifth section's own claim, which is the one with an argument behind it: AI agents
# is a signpost to /connections rather than a second copy of it, so the connector markup
# appears on exactly one page in this app.
#
# The names are spelled out here rather than read from the template, which would be the
# template asserting itself. "Weight plates" not "Equipment" and "Wearables" not "Withings"
# are the renamings the issue asked for by name, and a section named after a vendor is the
# one this had to stop doing: Apple Health is a deferred ticket, and it lands under
# Wearables as another device rather than as a page rewrite.
module AimingAtOneSetting
  # In the order #529 asked for them, which is neither the order they were in nor the order
  # they were written in. Anchor first, because the anchor is the promise: a name can be
  # reworded, and a fragment is a URL somebody may have bookmarked or posted a redirect to.
  SECTIONS = [['weight-plates', 'Weight plates'], %w[wearables Wearables], ['ai-agents', 'AI agents'],
              ['time-and-week', 'Time and week'], ['session-length', 'Session length']].freeze

  # Reached through a method because a describe block is not inside this module lexically, so
  # the constant is not in scope there however the module is included.
  def sections = SECTIONS

  # The section index, as the hrefs it offers. Scoped to the nav that carries the aria-label
  # rather than to every anchor on the page, so a link somewhere else in settings that
  # happens to point at a fragment is not mistaken for part of it.
  def index_links
    body = last_response.body[%r{<nav[^>]*aria-label="Settings sections".*?</nav>}m].to_s
    body.scan(/<a\b[^>]*href="#([^"]*)"/).flatten
  end

  # The first nav in the document, which is the top bar: the layout renders it before <main>
  # and the section index lives inside the page. Its links, as whole tags, so a change of
  # address or of class is caught as well as a link added or taken away.
  def top_bar = last_response.body[%r{<nav\b.*?</nav>}m].to_s.scan(/<a\b[^>]*>/)

  # The same row, with the words in it, for the one claim that is about what an entry says
  # rather than about whether the row moved.
  def top_bar_html = last_response.body[%r{<nav\b.*?</nav>}m].to_s

  def headings = last_response.body.scan(%r{<h2[^>]*>\s*(.*?)\s*</h2>}m).flatten

  def section_ids = last_response.body.scan(/<section[^>]*id="([^"]*)"/).flatten

  # One form on the page, found by what it posts to, with its fields.
  def form_posting_to(action)
    last_response.body[%r{<form[^>]*action="#{Regexp.escape(action)}"[^>]*>.*?</form>}m]
  end

  def fields_of(form) = form.to_s.scan(/name="([^"]*)"/).flatten

  # Where a save came back to, fragment and all. Rack::Test hands back the Location header
  # unparsed, which is the only place the fragment survives -- a browser never sends it.
  def landed_on = last_response.headers['location']

  # One assistant authorized twice: a single registered client with two live grants behind
  # it, which is what a lifter who approved Claude, lost the connection and approved it again
  # actually has. connections_spec's `connect` mints a client per call and so cannot build it.
  def authorized_twice(account_id, name: 'Claude')
    application = DB[:oauth_applications].insert(
      name:, client_id: SecureRandom.uuid, client_secret: SecureRandom.hex,
      redirect_uri: 'https://claude.ai/api/mcp/auth_callback', scopes: 'read write'
    )
    2.times do
      DB[:oauth_grants].insert(account_id:, oauth_application_id: application, scopes: 'read write',
                               created_at: Time.now, expires_in: Time.now + 3600)
    end
  end
end

describe 'the settings page, grouped' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before do
    @account_id = login
    get '/settings'
  end

  # The grouping itself. Sections rather than a run of headings, because what is being
  # aimed at is a block of the page and not a line of it -- a fragment on an <h2> scrolls a
  # heading into view with its own form still below the fold on a phone.
  it 'is five named sections in the order they were asked for' do
    assert_equal sections.map(&:first), section_ids
  end

  it 'heads each one with the name it was asked to be called' do
    assert_equal sections.map(&:last), headings
  end

  # The renaming, pinned as an absence. Both old headings were accurate and both were the
  # wrong size: Equipment could have held a belt, a watch and a bar, and Withings is one
  # wearable of several this app might read one day.
  it 'no longer heads a section with a vendor or with a word that could mean anything' do
    refute_includes headings, 'Equipment'
    refute_includes headings, 'Withings'
  end

  # And the brand is still on the page, one level down, because "which wearable" is a
  # question the section has to answer -- in every state, including the connected one, which
  # otherwise says only "Connected on 3 Jan".
  it 'still says which wearable it means' do
    assert_includes last_response.body, '>Withings</h3>'
  end
end

describe 'aiming at one of them' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before do
    @account_id = login
    get '/settings'
  end

  it 'offers a link to every section, in the same order' do
    assert_equal sections.map(&:first), index_links
  end

  # The half of a fragment link that goes wrong silently: an anchor pointing at an id that
  # does not exist does nothing at all, on a page that looks exactly as it should. Asserted
  # the way skip_link_spec asserts the same thing about "Skip to content".
  it 'lands every one of them on something that exists' do
    index_links.each do |anchor|
      assert_includes last_response.body, %(id="#{anchor}"), "nothing on the page has id=#{anchor}"
    end
  end

  # It is the first thing on the page after its title and any notice, because an index below
  # two hundred lines of plate inventory is an index nobody scrolls to.
  it 'comes before the first section it points at' do
    index = last_response.body.index('aria-label="Settings sections"')
    first = last_response.body.index('id="weight-plates"')

    refute_nil index
    assert_operator index, :<, first
  end

  # A thumb target rather than five words of prose with underlines in them. 44px is the
  # figure the rest of this app sizes controls to -- min-h-11 -- and this row is the first
  # thing on the page reached for.
  it 'is tappable rather than merely clickable' do
    row = last_response.body[%r{<nav[^>]*aria-label="Settings sections".*?</nav>}m]

    assert_equal sections.length, row.scan('min-h-11').length
  end
end

describe 'the top bar, which this deliberately does not touch' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before { @account_id = login }

  # The decision, pinned. A dropdown was what the issue's words asked for and the answer was
  # the page instead, so the bar has to come through this unchanged -- asserted as "identical
  # on a page that was regrouped and a page that was not" rather than as a count of links, so
  # it cannot be satisfied by a bar that happens to have six of them for some other reason.
  it 'is the same row on settings as on any other page' do
    get '/workouts'
    elsewhere = top_bar
    get '/settings'

    assert_equal elsewhere, top_bar
  end

  # Named separately because it is the entry the issue's wording would have moved. #534 made
  # the argument for a nav that does not gain an entry; this is the same argument run
  # backwards, for one that does not lose one. People find things by position, and an entry
  # taken away moves every entry after it as surely as one added does.
  it 'still offers assistants, pointing where it always did' do
    get '/settings'

    assert_includes top_bar.join, 'href="/connections"'
    assert_includes top_bar_html, '>assistants</a>'
  end

  # And the sections did not leak upwards into it. A bar that grew five fragment links would
  # be the dropdown by another name, carried on every page by every lifter.
  it 'carries no section of the settings page' do
    get '/settings'

    assert_empty top_bar.grep(/href="[^"]*#/)
  end
end

describe 'the forms the grouping moved' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before do
    @account_id = login
    get '/settings'
  end

  # Four independent saves, still four. Moving markup under new headings is exactly the edit
  # that would quietly fold two forms into one -- a stray </form> is enough -- and the
  # symptom would be changing a plate count re-submitting a time zone.
  it 'still posts four separate answers to four separate addresses' do
    ['/settings', '/settings/zone', '/settings/week', '/settings/budget'].each do |action|
      refute_nil form_posting_to(action), "nothing on the page posts to #{action}"
    end
  end

  # The one form that deliberately carries two things at once, which is the one most at risk
  # from a heading being put between them: #369 separated the racks on the page and refused to
  # separate the submission, so that a lifter changing a bar and a handle in one sitting saves
  # once. Both racks are under Weight plates now, and they are still one post.
  it 'still sends both racks in a single save' do
    fields = fields_of(form_posting_to('/settings'))

    ['bar_weight', 'plates[45]', 'dumbbell_handle_weight', 'dumbbell_plates[45]'].each do |field|
      assert_includes fields, field
    end
  end
end

describe 'the two answers that now share a heading' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before do
    @account_id = login
    get '/settings'
  end

  # Each still carries its own field and nothing from its neighbour. The time zone and the
  # week start are under one heading now -- they are one idea, "when is it for me" -- and
  # sharing a heading is not sharing a Save.
  it 'keeps the two halves of time and week as two saves' do
    assert_includes fields_of(form_posting_to('/settings/zone')), 'time_zone'
    refute_includes fields_of(form_posting_to('/settings/zone')), 'week_starts_on'
    assert_includes fields_of(form_posting_to('/settings/week')), 'week_starts_on'
    refute_includes fields_of(form_posting_to('/settings/week')), 'time_zone'
  end

  it 'still saves what it always saved' do
    post '/settings/budget', { 'minutes' => '75', '_csrf' => token_for_form('/settings', '/settings/budget') }

    assert_equal 75, DB[:accounts].where(id: @account_id).get(:time_budget_minutes)
  end
end

describe 'where a save comes back to' do
  include Rack::Test::Methods
  include RouteOwnership
  include AimingAtOneSetting

  before do
    @account_id = login
    get '/settings'
  end

  # The section it was saved in, which is the other half of what the
  # anchors buy: a save that landed at the top would put a lifter who aimed at Session length
  # back above Weight plates, to aim again for the thing they had just finished with.
  it 'comes back to the section that was saved' do
    post '/settings/budget', { 'minutes' => '75', '_csrf' => token_for_form('/settings', '/settings/budget') }

    assert_equal '/settings#session-length', landed_on

    post '/settings/week', { 'week_starts_on' => '1', '_csrf' => token_for_form('/settings', '/settings/week') }

    assert_equal '/settings#time-and-week', landed_on
  end

  # The rack's save carries a count of the sessions it rewrote, and the two have to be in the
  # order a URL is written in: everything after the first `#` is fragment, so a query string
  # behind one would be read by nobody.
  it 'keeps the rack count in front of the fragment' do
    post '/settings', { 'bar_weight' => '45', 'plates' => { '45' => '2' },
                        '_csrf' => token_for_form('/settings', '/settings') }

    assert_match(%r{\A/settings(\?rerounded=\d+)?#weight-plates\z}, landed_on)
  end

  # Except the Withings flows, which come back to the top on purpose: what they have to say
  # is a notice about what just happened, and it is above the index because it is the answer
  # to the last thing asked rather than a fact about one section.
  it 'comes back to the notice rather than to a section when a connection is dropped' do
    Tectonic::WithingsConnection.store(@account_id, { 'access_token' => 'access-1', 'refresh_token' => 'refresh-1',
                                                      'expires_in' => 10_800, 'userid' => '9001' })
    post '/settings/withings/disconnect',
         { '_csrf' => token_for_form('/settings', '/settings/withings/disconnect') }

    assert_equal '/settings', landed_on
  end
end

describe 'the AI agents section' do
  include Rack::Test::Methods
  include RouteOwnership
  include Connecting
  include AimingAtOneSetting

  before { @account_id = login }

  # The whole of what the section is: a name, a sentence and a link. #529 wanted the
  # connector represented in this grouping, and representing it is not the same as holding
  # it -- connecting an assistant is a walk that leaves the site and comes back through an
  # approval screen, and a walk wants a page rather than a fifth of one.
  it 'points at the page the connector lives on' do
    get '/settings'
    section = last_response.body[%r{<section[^>]*id="ai-agents".*?</section>}m]

    assert_includes section, 'href="/connections"'
  end

  # And does not hold a second copy of it. Two copies of the address to paste into an
  # assistant is two places to change it and one of them will be missed -- which is #239's
  # argument about class lists, made about something a lifter pastes into a client that then
  # holds a token for their whole account.
  it 'does not put the connector on two pages' do
    with_base_url('https://tectonicplates.app') { get '/settings' }

    refute_includes last_response.body, 'tectonicplates.app/mcp'
    refute_includes last_response.body, 'id="mcp-url"'
    refute_includes last_response.body, 'Add custom connector'
  end
end

describe 'how many assistants the AI agents section says are connected' do
  include Rack::Test::Methods
  include RouteOwnership
  include Connecting
  include AimingAtOneSetting

  before { @account_id = login }

  # The count is what lets somebody decide the link is not worth following -- the same job
  # the sentence in Wearables does for the review list. It is the ordinary answer that
  # matters most: an account with no assistant is told so rather than shown a bare link.
  it 'says nothing is connected when nothing is' do
    get '/settings'

    assert_includes last_response.body, 'nothing is connected yet'
  end

  it 'counts the assistants that are' do
    connect(@account_id, name: 'Claude')
    get '/settings'

    assert_includes last_response.body, '1 assistant'
    assert_includes last_response.body, 'is connected'
  end

  # Agreeing its verb with its count, which #538 had to go back and fix on the review list's
  # own sentence. One is where a count starts rather than an edge case.
  it 'agrees its verb with more than one' do
    connect(@account_id, name: 'Claude')
    connect(@account_id, name: 'ChatGPT')
    get '/settings'

    assert_includes last_response.body, '2 assistants'
    assert_includes last_response.body, 'are connected'
  end
end

describe 'what the count of assistants leaves out' do
  include Rack::Test::Methods
  include RouteOwnership
  include Connecting
  include AimingAtOneSetting

  before { @account_id = login }

  # A grant this account does not hold is not a connection of theirs, which is the one way a
  # count on a page can be worse than no count at all.
  it 'counts only this account and only live grants' do
    connect(@account_id, name: 'Claude', revoked_at: Time.now)
    # A stranger's connection, made without logging in as them: `login` would take the
    # session with it and the page below would be theirs rather than this account's, which
    # is an assertion that passes for the wrong reason.
    email, = make_account
    connect(DB[:accounts].where(email:).get(:id), name: 'Claude')
    get '/settings'

    assert_includes last_response.body, 'nothing is connected yet'
  end

  # Two authorizations of the same client are one assistant, which is the fold /connections
  # already does: a lifter who has approved Claude three times has one connection and three
  # rows behind it, and a settings page saying "3 assistants are connected" would disagree
  # with the page it links to.
  it 'counts an assistant authorized twice once' do
    authorized_twice(@account_id)
    get '/settings'

    assert_includes last_response.body, '1 assistant'
    assert_equal Tectonic::Connection.for_account(@account_id).length,
                 Tectonic::Connection.count_for_account(@account_id)
  end
end

