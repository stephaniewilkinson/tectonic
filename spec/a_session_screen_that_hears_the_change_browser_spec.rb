# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# #592, in a real browser against a real Puma: the one place the doorbell can be shown to work
# end to end. An assistant correcting a set is a write the screen did not make, and it used to
# appear at the next fifteen-second poll. It should appear in a second or two.
describe 'a set changed behind an open session screen' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  before do
    account_id = sign_in_as_somebody_new
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    @set_id = DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                               is_completed: false, is_barbell: true)
    visit "/workouts/#{workout_id}/session"
    assert_text '155 lb'
  end

  # Six seconds is the claim, and it is well inside the poll's fifteen: the change is written a
  # moment after the page loads, so the poll on its own could not show it for another fourteen.
  it 'shows the change within seconds rather than at the next poll' do
    sleep 1
    DB[:sets].where(id: @set_id).update(weight: 165)

    using_wait_time(6) { assert_text '165 lb' }
  end
end

