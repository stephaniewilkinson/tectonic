# frozen_string_literal: true

require_relative 'spec_helper'

# The consent screen carries no analytics, and that is the only thing here worth a spec.
#
# Everything else about Fathom is a script tag and a dashboard setting: which environments
# are counted is the allowed-domains firewall on the Fathom site, not a condition in this
# app. This is different in kind. It is the one page where a tap hands an API client the
# account, its CSP allows no script from anywhere, and adding a third-party origin to it
# would be a security decision made by accident while editing a layout.
describe 'the OAuth consent screen' do
  it 'loads no analytics' do
    layout = File.read(File.expand_path('../views/oauth_layout.erb', __dir__))

    refute_includes layout, 'usefathom.com'
  end
end

# The second thing worth a spec, added with #252: that there is one counter and not two.
#
# A tinyanalytics pixel sat twenty-two lines below the Fathom tag and below a comment
# saying Fathom was the only third-party script on the site. Nothing caught it because
# nothing was looking -- the page worked, both vendors reported numbers, and the numbers
# disagreed with each other in a way neither could be blamed for.
#
# The vendor is asserted by absence rather than by counting script tags, because the
# failure mode is a second one being added, and a second one always arrives with a name.
ANALYTICS_VENDORS = {
  'app.tinyanalytics.io' => 'removed in #252: Fathom is the counter #185 chose and gave reasons for'
}.freeze

describe 'the pages an account is counted on' do
  # Every view, not only the layout: a pixel pasted into a single page counts that page
  # and is exactly as hard to notice.
  it 'loads no counter but the one that was decided on' do
    Dir[File.expand_path('../views/**/*.erb', __dir__)].each do |view|
      markup = File.read(view)

      ANALYTICS_VENDORS.each do |vendor, why|
        refute_includes markup, vendor, "#{File.basename(view)} loads #{vendor}, #{why}"
      end
    end
  end

  # The comment above the Fathom tag is the thing a person reads before deciding whether
  # script-src can be narrowed, so it being true is worth as much as the tag being right.
  it 'says in the layout that Fathom is the only one' do
    layout = File.read(File.expand_path('../views/layout.erb', __dir__))

    assert_includes layout, 'the only third-party script the site loads'
    assert_includes layout, 'cdn.usefathom.com'
  end
end

