# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_library'
# The RouteOwnership helpers (login, make_account, token_for), for the note specs that
# post the way a form does and then read the row back. Requiring a sibling spec for its
# helpers is what mcp_training_tools_spec does with mcp_spec, and require_relative is
# idempotent, so nothing is defined twice on a full run.
require_relative 'route_ownership_spec'
require 'securerandom'

# Seed the built-in library once, the way `rake library:exercises` does on deploy.
Tectonic::Exercise.load_library

def sign_up
  email = "#{SecureRandom.hex}@gmail.com"
  password = SecureRandom.hex
  visit '/'
  click_on 'Sign up'
  fill_in 'email', with: email
  fill_in 'password', with: password
  click_on 'Sign up'
end

def add_exercise(name, note: nil)
  visit '/exercises'
  click_on 'Add a new exercise'
  fill_in 'name', with: name
  fill_in 'note', with: note if note
  click_on 'Save'
end

describe 'the exercise library' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'loads idempotently, with no duplicate rows on a second run' do
    created, skipped = Tectonic::Exercise.load_library
    assert_equal 0, created
    assert_equal Tectonic::Exercise::LIBRARY.length, skipped
    assert_equal Tectonic::Exercise::LIBRARY.length, Tectonic::Exercise.where(account_id: nil).count
  end
end

describe 'a new account' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'sees the library and can add its own alongside it' do
    sign_up
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    add_exercise 'My Garage Special'
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    assert_includes page.body, 'My Garage Special'
  end
end

describe 'a private exercise' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'is invisible to and uneditable by another account' do
    sign_up
    add_exercise 'Private Move A'
    path = current_path
    Capybara.reset_sessions!
    sign_up
    visit '/exercises'
    assert_includes page.body, 'Back Squat'
    refute_includes page.body, 'Private Move A'
    visit path
    refute_includes page.body, 'Private Move A'
    visit "#{path}edit"
    refute_includes page.body, 'Private Move A'
  end
end

describe 'a library exercise' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'shows as read-only and refuses a direct edit' do
    sign_up
    visit '/exercises'
    click_on 'Back Squat'
    assert page.has_no_link?('Edit')
    assert_includes page.body, 'Built-in'
    visit "#{current_path}/edit"
    refute_includes page.current_path, 'edit'
  end
end

# A private movement belonging to somebody else, reachable only by guessing its id.
def another_accounts_exercise
  email, = make_account
  owner = DB[:accounts].where(email:).get(:id)
  DB[:exercises].insert(name: "Private #{SecureRandom.hex(4)}", account_id: owner)
end

# What a lifter or an assistant typed, verbatim, with an element hidden in it. Both
# halves of the assertion matter: the characters have to reach the page, and nothing may
# come out of them but characters.
NOTE_WITH_MARKUP = 'watch the knee: <b id="pwned">valgus</b>'

describe 'a note on a movement you own' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'is written from the form and read back on the movement page' do
    sign_up
    add_exercise "Cue #{SecureRandom.hex(4)}", note: 'this helps correct valgus'

    assert_includes page.text, 'this helps correct valgus'
  end

  it 'is changed and then cleared through the same form' do
    sign_up
    add_exercise "Cue #{SecureRandom.hex(4)}", note: 'brace before you unrack'
    click_on 'Edit'
    fill_in 'note', with: 'ribs down'
    click_on 'Save'

    assert_includes page.text, 'ribs down'
    click_on 'Edit'
    fill_in 'note', with: ''
    click_on 'Save'

    refute_includes page.text, 'ribs down'
  end
end

# Blank and absent are the same thing to a reader and different things to Ruby, where ''
# is truthy: a note stored as an empty string would draw its own empty paragraph on the
# movement's page forever, so only one of the two spellings is ever written.
describe 'a note left blank' do
  it 'is stored as nothing at all rather than as an empty string' do
    assert_nil Tectonic::Exercise.clean_note('')
    assert_nil Tectonic::Exercise.clean_note("  \n ")
    assert_equal 'ribs down', Tectonic::Exercise.clean_note("  ribs down\n")
  end
end

describe 'a note containing markup' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour

  it 'is shown as the characters that were typed rather than run as HTML' do
    sign_up
    add_exercise "Cue #{SecureRandom.hex(4)}", note: NOTE_WITH_MARKUP

    assert page.has_no_css?('b#pwned', visible: :all)
    assert_includes page.text, NOTE_WITH_MARKUP
  end

  # The textarea is the other place the note is written into the page, and the easier of
  # the two to get wrong: an unescaped angle bracket there closes the field early, and
  # everything after it becomes markup in the form rather than text in the box.
  it 'comes back into the edit form as the same characters' do
    sign_up
    add_exercise "Cue #{SecureRandom.hex(4)}", note: NOTE_WITH_MARKUP
    click_on 'Edit'

    assert_equal NOTE_WITH_MARKUP, find_field('note').value
  end
end

# A note is about the movement, so it follows the movement's ownership rule exactly as
# the name does. Library rows have a nil account and sit on every account's page: a note
# written to one would be a value one account wrote and every other account reads.
describe 'who may write a note' do
  include Rack::Test::Methods
  include RouteOwnership

  before { login }

  it 'refuses to note a library movement, which every account reads' do
    library = Tectonic::Exercise.where(account_id: nil).order(:id).first
    post '/exercises', { id: library.id.to_s, name: library.name, icon_url: '',
                         note: 'mine alone', '_csrf' => token_for('/exercises/new') }

    assert_nil Tectonic::Exercise.where(id: library.id).get(:note)
  end

  it "refuses to note another account's private movement" do
    hidden = another_accounts_exercise
    post '/exercises', { id: hidden.to_s, name: 'Renamed', icon_url: '',
                         note: 'mine alone', '_csrf' => token_for('/exercises/new') }

    assert_nil DB[:exercises].where(id: hidden).get(:note)
  end
end

