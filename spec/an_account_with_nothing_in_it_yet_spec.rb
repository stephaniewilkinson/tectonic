# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its login; idempotent require

# #636. A new account that closed Start here without acting came back to a blank calendar with
# a button to continue a workout that did not exist, a workouts list that was a header row, and
# no way back to the page that explained anything.
describe 'an account with nothing in it yet' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @account_id = login }

  it 'is pointed back to Start here from the calendar' do
    get '/'

    assert_includes last_response.body, 'Nothing logged or planned yet.'
    assert_includes last_response.body, 'href="/start"'
  end

  it 'is not offered a workout to continue' do
    get '/'

    refute_includes last_response.body, 'Continue a workout'
  end

  it 'gets a sentence on the workouts list rather than an empty table' do
    get '/workouts'

    assert_includes last_response.body, 'No sessions yet.'
    refute_includes last_response.body, '<thead'
  end
end

describe 'an account with training in it' do
  include Rack::Test::Methods
  include RouteOwnership

  before do
    @account_id = login
    own_workout(@account_id)
  end

  # A quiet month on an account that has trained is a different sentence from an empty account.
  it 'still says only that the month was quiet' do
    get "/?month=#{(Date.today << 13).strftime('%Y-%m')}"

    assert_includes last_response.body, 'Nothing trained or planned this month.'
    assert_includes last_response.body, 'Continue a workout'
  end
end

# Start here is reached only on the first sign-in of an empty account, so something permanent
# has to link to it.
describe 'the way back to Start here' do
  include Rack::Test::Methods
  include RouteOwnership

  it 'is at the foot of settings' do
    login
    get '/settings'

    assert_includes last_response.body, 'href="/start"'
  end
end

