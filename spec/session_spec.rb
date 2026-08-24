# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# The picker needs a selectable exercise; the library gives us one with no setup.
Tectonic::Exercise.load_library

def sign_up_for_session
  email = "#{SecureRandom.hex}@gmail.com"
  password = SecureRandom.hex
  visit '/'
  click_on 'Sign up'
  fill_in 'email', with: email
  fill_in 'email-confirm', with: email
  fill_in 'password', with: password
  fill_in 'password-confirm', with: password
  click_on 'Sign up'
  DB[:accounts].where(email:).get(:id)
end

# A warmup and a working set of one lift, written the way ProgramGenerator writes them:
# with the prescription kept in planned_weight and planned_reps. Inserted rather than
# typed in, because a ramp is generated and there is no form that produces one.
def generated_session(account_id)
  workout_id = DB[:workouts].insert(account_id:, date: Time.now)
  exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
  common = { workout_id:, exercise_id:, is_barbell: true, is_completed: false }
  warmup_id = DB[:sets].insert(**common, weight: 95, reps: 5, is_warmup: true,
                                         planned_weight: 95, planned_reps: 5)
  DB[:sets].insert(**common, weight: 155, reps: 5, is_warmup: false,
                             planned_weight: 155, planned_reps: 5)
  [workout_id, warmup_id]
end

describe 'the session view' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  it 'marks a set done in place with htmx, without reloading' do
    sign_up_for_session
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{workout}session"
    page.execute_script('window.stayed = true')
    click_button 'Done'
    assert page.has_button?('Undo'), 'the set should toggle to Undo in place'
    assert page.evaluate_script('window.stayed === true'), 'the tap should not reload the page'
  end
end

describe 'revising a set in the session' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  it 'records the weight actually lifted and marks the set done' do
    sign_up_for_session
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{workout}session"
    find('summary', text: 'Lifted something else').click
    fill_in 'Weight', with: '145'
    click_button 'Save'
    assert_includes page.body, '145'
    assert page.has_button?('Undo')
  end
end

# Driven in a real browser on purpose. What refused these weights was the browser's own
# step validation, which never reaches the app: nothing posts, so a Rack::Test spec would
# have passed throughout. The failure is only visible where the bubble is.
describe 'a weight that is not on the five pound grid' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  # A step is counted from a step base, which with no min attribute is the input's own
  # value. The new-set form counted fives from zero and refused 138 outright; the session
  # then counted fives from 138 and refused 135, which is the screenshot on #114. 138 is
  # ordinary data -- a rack with 1 lb plates has an increment of 2.
  it 'can be logged, and then revised to one the old grid refused' do
    sign_up_for_session
    visit '/workouts/new'
    click_on 'Save'
    workout = current_path
    visit "#{workout}sets/new"
    select 'Back Squat', from: 'exercise_id'
    fill_in 'weight', with: '138'
    fill_in 'reps', with: '5'
    click_on 'Save'
    visit "#{workout}session"
    find('summary', text: 'Lifted something else').click
    fill_in 'Weight', with: '135'
    click_button 'Save'

    assert page.has_text?('135 × 5'), 'the revised weight should be on the row'
  end
end

describe 'a warmup taken differently from the ramp' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec

  # The ramp is computed from a percentage of the top set, and a warmup row used to carry
  # Done and nothing else -- so a lifter who started on a lighter bar left the session
  # claiming a ramp that did not happen, with no tint to say otherwise.
  it 'records what was lifted and tints the row as changed' do
    _account_id, warmup_id = editable_warmup
    fill_in "weight-#{warmup_id}", with: '75'
    click_button 'Save'

    assert page.has_css?('li.bg-amber-50', text: '75 × 5'), 'the warmup row should read as changed'
    assert page.has_text?('planned 95 × 5'), 'and should say what it was changed from'
  end

  # The first summary on the page belongs to the warmup: the warmup list is rendered
  # before the working sets, which is the order they are lifted in.
  def editable_warmup
    account_id = sign_up_for_session
    workout_id, warmup_id = generated_session(account_id)
    visit "/workouts/#{workout_id}/session"
    first('summary', text: 'Lifted something else').click
    [account_id, warmup_id]
  end
end

