# frozen_string_literal: true

# #716. A session an assistant writes while the lifter already has the screen open loads with
# nothing ratable -- warmups first, the working sets a minute later -- and the poll that
# brings the working sets in redraws #session-body and nothing else. The RPE footer used to be
# decided once, at load, so on exactly those sessions it never came.

require_relative 'spec_helper'
require_relative 'session_spec' # reuses its browser sign-up
require 'securerandom'

describe 'the rating scale arriving with the sets that need it' do
  include CapybaraBehaviour
  include BrowserSpec

  before do
    account_id = sign_up_for_session
    @workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    @exercise_id = DB[:exercises].insert(name: "Deadlift #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: @workout_id, exercise_id: @exercise_id, weight: 95, reps: 5,
                     is_warmup: true, is_barbell: true, is_completed: false)
    visit "/workouts/#{@workout_id}/session"
  end

  def the_assistant_writes_a_working_set
    DB[:sets].insert(workout_id: @workout_id, exercise_id: @exercise_id, weight: 155, reps: 3,
                     is_warmup: false, is_barbell: true, is_completed: false)
    page.execute_script("htmx.trigger(document.getElementById('session-poll'), 'load')")
  end

  it 'is not shown while only warmups are on screen' do
    refute has_css?('#rpe-help', visible: true)
  end

  it 'comes in when a working set arrives by poll, and lifts the rest timer clear of it' do
    the_assistant_writes_a_working_set

    assert has_css?('#rpe-help', visible: true, wait: 5)
    timer = find('#rest-timer', visible: :all)
    assert_includes timer[:class], 'bottom-[calc(2.75rem+env(safe-area-inset-bottom))]'
    refute_includes timer[:class], 'bottom-[env(safe-area-inset-bottom)]'
  end
end

