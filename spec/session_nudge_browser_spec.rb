# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# The nudge, in a real browser. #410.
#
# Everything about this feature is a clock, and a clock is the one thing a Rack::Test request
# cannot have. The server-side half is specced without a browser -- when the session last
# moved, how long to wait, what the answer stamps -- and this is the half that only exists
# once something is running: whether the bar actually appears, and whether the two buttons on
# it do what they say.
module SessionNudge
  def an_account_with_a_quiet_session(ago: 45 * 60)
    email = "#{SecureRandom.hex}@gmail.com"
    password = SecureRandom.hex
    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: email
    fill_in 'password', with: password
    click_on 'Sign up'
    account_id = DB[:accounts].where(email:).get(:id)
    [account_id, a_quiet_session(account_id, ago:)]
  end

  def a_quiet_session(account_id, ago:)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                     is_completed: true, is_barbell: true, planned_rest_seconds: 180,
                     completed_at: Time.now - ago)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5, is_warmup: false,
                     is_completed: false, is_barbell: true, planned_rest_seconds: 180)
    workout_id
  end
end

describe 'arriving at a session that has been quiet for three quarters of an hour' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SessionNudge

  before do
    _account_id, @workout_id = an_account_with_a_quiet_session
    visit "/workouts/#{@workout_id}/session"
  end

  # The question raises itself on arrival rather than twenty minutes into the visit, which is
  # the difference between this and the rest timer beside it: a session opened an hour after
  # its last set should not start a countdown, and absolutely should be asked about.
  it 'asks whether the session is still going' do
    assert_text 'Still training?'
  end

  # "Still training?" on its own is a question out of nowhere. The number is the reason, and a
  # lifter who has been talking to somebody recognises it immediately.
  it 'says how long it has been quiet' do
    assert_text(/Nothing logged for \d+m/)
  end
end

describe 'a session that is plainly still running' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SessionNudge

  it 'is not asked anything' do
    _account_id, workout_id = an_account_with_a_quiet_session(ago: 60)
    visit "/workouts/#{workout_id}/session"

    refute_text 'Still training?'
  end
end

describe 'answering "still going"' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SessionNudge

  # It closes the bar without touching the session. Nothing is stamped, nothing is written,
  # and the lifter gets on with the set they were in the middle of.
  it 'puts the question away and leaves the session open' do
    _account_id, workout_id = an_account_with_a_quiet_session
    visit "/workouts/#{workout_id}/session"
    click_on 'Still going'

    refute_text 'Still training?'
    assert_nil Tectonic::Workout[workout_id].finished_at
  end
end

# The label carries a typographic apostrophe, so this is matched on the character the page
# actually renders rather than on the one a keyboard produces.
describe 'answering "that is it"' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SessionNudge

  # The whole of #410's first half, seen end to end: the session is closed, and it is closed
  # at the set rather than at the moment of answering -- so the forty-five minutes of silence
  # do not become forty-five minutes of training.
  it 'closes the session at its last set rather than at now' do
    _account_id, workout_id = an_account_with_a_quiet_session
    last = Tectonic::WorkoutSet.where(workout_id:).max(:completed_at)
    visit "/workouts/#{workout_id}/session"
    click_on 'That’s it'

    finished = Tectonic::Workout[workout_id].finished_at

    refute_nil finished
    assert_in_delta last.to_f, finished.to_f, 2
  end

  it 'lands on the record of the session it just closed' do
    _account_id, workout_id = an_account_with_a_quiet_session
    visit "/workouts/#{workout_id}/session"
    click_on 'That’s it'

    assert_equal "/workouts/#{workout_id}", current_path
  end
end

# A set ticked off is the session plainly moving, so the question goes away and the quiet
# restarts from the tap. Without this the bar would sit there through the next three sets,
# asking about a silence that ended.
describe 'a quiet session that starts moving again' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include SessionNudge

  it 'stops asking once a set is ticked off' do
    _account_id, workout_id = an_account_with_a_quiet_session
    visit "/workouts/#{workout_id}/session"

    assert_text 'Still training?'

    first('button', text: 'Done').click

    refute_text 'Still training?'
  end
end

