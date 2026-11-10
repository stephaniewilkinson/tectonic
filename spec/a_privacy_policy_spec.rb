# frozen_string_literal: true

require_relative 'spec_helper'

# Swaps who the policy names for one test, so both states of the route can be exercised.
module PrivacyOperator
  def with_operator(operator)
    original = Tectonic::PRIVACY_OPERATOR
    Tectonic.send(:remove_const, :PRIVACY_OPERATOR)
    Tectonic.const_set(:PRIVACY_OPERATOR, operator)
    yield
  ensure
    Tectonic.send(:remove_const, :PRIVACY_OPERATOR)
    Tectonic.const_set(:PRIVACY_OPERATOR, original)
  end
end

# The privacy policy, and the rule that it is never published half-filled. #682.
describe 'the privacy policy' do
  include Rack::Test::Methods
  include PrivacyOperator

  def app = Tectonic.app

  it 'is not served while who runs it or how to reach them is missing' do
    with_operator({ name: 'A Lifter', address: nil, email: 'help@example.org' }) do
      get '/privacy'
      assert_equal 404, last_response.status
    end
  end

  it 'names who runs it and where to write once all three are known' do
    with_operator({ name: 'A Lifter', address: 'PO Box 1, Portland, OR', email: 'help@example.org' }) do
      get '/privacy'
      assert_equal 200, last_response.status
      assert_includes last_response.body, 'A Lifter'
      assert_includes last_response.body, 'PO Box 1, Portland, OR'
      assert_includes last_response.body, 'help@example.org'
      refute_match(/\[[A-Z ]+\]/, last_response.body)
    end
  end
end

describe 'the privacy policy, against the app' do
  include Rack::Test::Methods
  include PrivacyOperator

  def app = Tectonic.app

  # Two sentences the draft had that the app did not back up. If either feature arrives, this is
  # the spec that says the page has to change with it.
  it 'promises only what the app does about deletion and retention' do
    with_operator({ name: 'A Lifter', address: 'PO Box 1', email: 'help@example.org' }) do
      get '/privacy'

      assert_includes last_response.body, 'To delete your account'
      assert_includes last_response.body, 'assistant activity logs included'
    end
  end
end

