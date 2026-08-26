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

