# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'

# What `plugin :render, escape: true` buys, pinned from both sides.
#
# The two failure modes are opposite and an ordinary spec notices neither. Escaping too
# little puts an account's own text into the page as markup, which is the hole this
# closes. Escaping too much turns a helper whose whole job is to emit markup into visible
# angle brackets -- not a security problem, but a broken page, and the symptom of a
# mangled csrf_tag is a 403 on submit rather than anything that points back here.
#
# These assert against `page.body`, which for the Selenium driver is the DOM serialized
# back to HTML. That is the distinction being tested: a name that arrived as text is a
# text node and serializes back with its angle brackets escaped, while a name that
# arrived as markup is an element and serializes as one.
MARKUP_NAME = '<script>alert(1)</script> Squat'
# A name that ends the attribute it is printed into rather than the element around it.
# The edit form prints the name into value="...", where a bare double quote is enough:
# everything after it is read as further attributes on the input.
QUOTE_NAME = 'Squat" onmouseover="alert(1)'

def escaping_sign_up
  email = "#{SecureRandom.hex}@gmail.com"
  password = SecureRandom.hex
  visit '/create-account'
  fill_in 'email', with: email
  fill_in 'email-confirm', with: email
  fill_in 'password', with: password
  fill_in 'password-confirm', with: password
  click_on 'Sign up'
  DB[:accounts].where(email:).get(:id)
end

def escaping_add_exercise(name)
  visit '/exercises'
  click_on 'Add a new exercise'
  fill_in 'name', with: name
  click_on 'Save'
end

describe 'a movement named with markup' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  before do
    escaping_sign_up
    escaping_add_exercise(MARKUP_NAME)
  end

  it 'reaches its own page as text rather than as a script element' do
    refute_includes page.body, '<script>alert(1)</script> Squat'
    assert_includes page.body, '&lt;script&gt;'
  end

  it 'reaches the exercises list as text' do
    visit '/exercises'

    refute_includes page.body, '<script>alert(1)</script> Squat'
    assert_includes page.body, '&lt;script&gt;'
  end

  it 'creates no script element on the page that shows it' do
    assert_equal 0, page.evaluate_script(
      "Array.from(document.querySelectorAll('script')).filter(s => s.textContent.includes('alert(1)')).length"
    )
  end
end

describe 'a movement whose name would close an attribute' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  before do
    escaping_sign_up
    escaping_add_exercise(QUOTE_NAME)
  end

  it 'keeps the whole name inside the edit form value' do
    click_on 'Edit'

    assert_equal QUOTE_NAME, page.evaluate_script("document.getElementById('name').value")
  end

  it 'gives the input no onmouseover attribute of its own' do
    click_on 'Edit'

    assert_nil page.evaluate_script("document.getElementById('name').getAttribute('onmouseover')")
  end
end

describe 'the helpers that exist to emit markup' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  # Each of these sits behind <%== and would be worthless escaped.
  it 'still writes a real hidden csrf input on the sign-in form' do
    visit '/login'

    assert_equal 1, page.evaluate_script("document.querySelectorAll('form input[type=hidden]').length")
  end

  it 'still writes a real stylesheet link in the layout' do
    visit '/welcome'

    assert_operator page.evaluate_script("document.querySelectorAll('link[rel=stylesheet]').length"), :>=, 1
  end
end

describe 'an entity that passes through an expression' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  # The month tally joined on "&middot;" and load_label built its "&times;" the same way,
  # inside Ruby strings that this tag now escapes. Both are characters now. Pinning it is
  # how the next person to reach for an entity in a string finds out here rather than on
  # a phone mid-session.
  it 'draws the multiplication sign in a set label as a character' do
    account_id = escaping_sign_up
    exercise = Tectonic::Exercise.create(name: 'Back Squat', account_id:, is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: Time.now)
    Tectonic::Set.create(workout_id: workout.id, exercise_id: exercise.id, weight: 225,
                         reps: 5, is_warmup: false, is_completed: false, is_barbell: true)

    visit "/workouts/#{workout.id}/session"

    refute_includes page.body, '&amp;times;'
    assert_includes page.text, '225 × 5'
  end
end

