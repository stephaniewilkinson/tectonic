# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its login; idempotent require

# #630. /start's second way in is logging a session already trained, and the set form's
# Completed box came up clear -- so the session was filed as planned, or dated yesterday as
# missed, and nothing it promised appeared. The box starts ticked for a session dated today or
# earlier now, and clear for one in the future.
describe 'the Completed box on a new set' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @account_id = login }

  def box_for(date, query = '')
    workout_id = DB[:workouts].insert(account_id: @account_id, date:)
    get "/workouts/#{workout_id}/sets/new#{query}"
    last_response.body[/<input id="is_completed"[^>]*>/m]
  end

  it 'starts ticked for a session trained yesterday' do
    assert_includes box_for(Date.today - 1), 'checked'
  end

  it 'starts ticked for a session today' do
    assert_includes box_for(Date.today), 'checked'
  end

  it 'starts clear for a session still ahead' do
    refute_includes box_for(Date.today + 3), 'checked'
  end

  # The session screen has the Done button for this, and a set added mid-session has not been
  # lifted yet.
  it 'starts clear when opened from the session screen' do
    refute_includes box_for(Date.today, '?return_to=session'), 'checked'
  end
end

