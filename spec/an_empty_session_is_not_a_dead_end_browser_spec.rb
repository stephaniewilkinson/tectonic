# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'
require 'date'

# #578 in a real browser, which is the only place two of its claims can be made.
#
# The Rack::Test file beside this one can say that the session screen carries a link and that
# the swap responses do not. It cannot say what a lifter standing in a gym gets, and that is
# the whole issue: whether an empty session can be walked out of, and whether the way out is
# still there after the screen has swapped itself half a dozen times.
#
# **Why a Done tap is worth driving rather than asserting on the response.** The control sits
# outside #session-body on purpose, and the response to a tap is a lift panel, a progress
# header and three out-of-band fragments -- none of which mention it. That is exactly what a
# control htmx had been told to replace would *also* look like from the server's side on the
# tap that removed it, because a swap is defined by what arrives and by what the page was
# told to do with it. Only a browser has both halves.
module EmptySessionInABrowser
  def a_lifter
    email = "#{SecureRandom.hex}@gmail.com"
    password = SecureRandom.hex
    visit '/'
    click_on 'Sign up'
    fill_in 'email', with: email
    fill_in 'password', with: password
    click_on 'Sign up'
    DB[:accounts].where(email:).get(:id)
  end

  # The session in the screenshot: a row in workouts, dated today, with nothing pointing at
  # it. How it got that way is not this file's business -- see the rack spec -- but this is
  # what the generator leaves behind for a programme day with no lifts written on it.
  def an_empty_session
    @account_id = a_lifter
    @movement = "Landmine Press #{SecureRandom.hex(4)}"
    DB[:exercises].insert(name: @movement, account_id: @account_id)
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Date.today)
    visit "/workouts/#{@workout_id}/session"
    @workout_id
  end

  def a_session_with_a_lift
    @account_id = a_lifter
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Date.today)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}",
                                        account_id: @account_id)
    @set_id = DB[:sets].insert(workout_id: @workout_id, exercise_id:, weight: 155, reps: 5,
                               is_warmup: false, is_completed: false, is_barbell: true)
    visit "/workouts/#{@workout_id}/session"
    @workout_id
  end

  # The picker from #549, driven the way a thumb drives it: tap, type part of the name, commit
  # with Enter. Deliberately not `select ... from: 'exercise_id'`, which would reach past the
  # combobox to the select it hides -- this file has to fail if the way in to the form lands
  # on a page whose movement control does not work.
  def pick(movement)
    search = find('#exercise-search')
    search.click
    search.send_keys(*movement.chars)
    search.send_keys(:enter)
  end

  def sets_now = DB[:sets].where(workout_id: @workout_id).count
end

describe 'walking out of a session with nothing written for it' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include EmptySessionInABrowser

  before { an_empty_session }

  # The issue, start to finish. Before this the screen offered "finish workout" and "Add a
  # note" and the lifter's only way to train was to leave the app's account of the day behind.
  it 'reaches the set form and comes back with a set on the session' do
    click_on 'Add a lift'
    pick @movement
    fill_in 'weight', with: '95'
    fill_in 'reps', with: '8'
    click_on 'Save'

    assert_equal "/workouts/#{@workout_id}/session", page.current_path
    assert_equal 1, sets_now
    assert_text @movement
  end
end

describe 'the way in to a new lift, while the session swaps itself' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include EmptySessionInABrowser

  before { a_session_with_a_lift }

  # Outside #session-body, asserted as a lifter would notice it: tap Done, which replaces the
  # lift panel and re-renders the progress header out of band, and the way in is still there.
  # Once, not twice -- a control rendered inside the swapped region would come back beside the
  # one already on the page.
  it 'is still there, once, after a set is ticked off' do
    click_on 'Done'

    assert_selector :button, text: 'Undo', wait: 5
    assert_equal 1, all('a', text: 'Add a lift').length
  end
end

