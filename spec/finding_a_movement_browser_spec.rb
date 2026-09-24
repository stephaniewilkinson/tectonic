# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

Tectonic::Exercise.load_library

# Picking a movement on the set form, once it is a search box. #525.
#
# Almost all of this needs a real browser, because almost all of it is a script: the list is
# in the page either way, and what changed is which of it is on screen, which row the
# keyboard is on, and what the select underneath is carrying by the time Save is pressed. A
# Rack::Test spec can assert the markup and nothing about the control.
#
# The two rack describes at the top are the exception, and they are the half that would rot
# quietly. They pin what a browser running no JavaScript at all is served -- which is the
# form that shipped before this, select and options and the right one marked -- because that
# fallback is invisible when it works and is the whole reason the select was kept rather
# than replaced by a hidden input. This file consequently runs in the browser job whole,
# which the Rakefile's split expects and says so.
module FindingAMovement
  # A library movement and one of the account's own, both with "Row" in the name, so that a
  # search crosses the two groups and a narrower one does not. The library names are real:
  # a hand-inserted row with no account behind it is a library row, and the teardown
  # deliberately keeps those, so inventing one would leak into every later test in the run.
  LIBRARY_ROWS = ['Bent Over Row', 'Pendlay Row', 'Yates Row', 'Landmine Row'].freeze
  OWN_ROW = 'Single-Arm DB Row'

  # A copy of the sign-up walk until #575 put a confirmation email in the middle of one. The
  # shared helper in spec_helper writes the account and drives only the sign-in, and the note
  # there says why: nothing in this file is about how an account comes to exist.
  def a_lifter = sign_in_as_somebody_new

  # The account's own movements. Which of them leads is decided by the order the route reads
  # in (#551) and by the library sitting above them, so what an untouched form posts is asked
  # of the model in `first_movement` rather than assumed to be either of these two.
  def a_workout_to_log(account_id)
    @own = { OWN_ROW => DB[:exercises].insert(name: OWN_ROW, account_id:),
             'Cable Fly' => DB[:exercises].insert(name: 'Cable Fly', account_id:) }
    DB[:workouts].insert(account_id:, date: Date.today)
  end

  def a_new_set_form
    account_id = a_lifter
    @workout_id = a_workout_to_log(account_id)
    visit "/workouts/#{@workout_id}/sets/new"
    @workout_id
  end

  # A set already logged against Cable Fly, which is not the first movement the picker offers
  # -- the library group is drawn above the account's own and this file seeds it -- so a picker
  # that forgot its selection shows up as a move rather than as a coincidence. The describe
  # that leans on that says so out loud rather than trusting this sentence.
  def a_set_to_edit
    account_id = a_lifter
    @workout_id = a_workout_to_log(account_id)
    @set_id = DB[:sets].insert(workout_id: @workout_id, exercise_id: @own['Cable Fly'],
                               weight: 40, reps: 12, is_warmup: false, is_completed: false)
    visit "/workouts/#{@workout_id}/sets/#{@set_id}/edit"
    @workout_id
  end

  def search_box = find('#exercise-search')

  # Opens the picker the way a thumb does.
  def open_picker = search_box.click

  def type(query)
    open_picker
    search_box.send_keys(*query.chars)
  end

  # The movements on screen, headings excluded. Capybara's visibility filter is what does
  # the work: a filtered-out option carries the hidden attribute, and hidden is display:none.
  def offered = all('#exercise-listbox [role="option"]').map(&:text)

  def headings = all('#exercise-listbox [role="presentation"] > span').map(&:text)

  # One offered movement as the pair a spec can still read after the list has closed over it:
  # a Selenium element reports no text while it is hidden, and choosing a movement hides it.
  def offered_row(index)
    row = all('#exercise-listbox [role="option"]')[index]
    [row.text, row['data-exercise-id']]
  end

  # What the form will actually post, which is the select and never the search box.
  def submitted_exercise_id = page.evaluate_script("document.getElementById('exercise_id').value")

  def exercise_on(set_id) = DB[:sets].where(id: set_id).get(:exercise_id)

  # What an untouched new-set form posts, worked out the way the route works it out rather
  # than written down here -- a constant would agree with the form only until somebody
  # changed the order the movements are read in, and then agree with nothing.
  def first_movement
    account_id = DB[:workouts].where(id: @workout_id).get(:account_id)
    Tectonic::Exercise.visible_to(account_id).library_first_by_name.first.id
  end
end

describe 'the set form with no JavaScript at all' do
  include Rack::Test::Methods
  include RouteOwnership
  include FindingAMovement

  before do
    @account_id = login
    @workout = own_workout(@account_id)
    @exercise = DB[:exercises].insert(name: "Cable Fly #{SecureRandom.hex(4)}", account_id: @account_id)
    @set = DB[:sets].insert(workout_id: @workout, exercise_id: @exercise, weight: 40, reps: 12,
                            is_warmup: false, is_completed: false)
  end

  # The fallback, stated outright. Nothing about picking a movement is new enough to be worth
  # losing when a script does not run, and the select is what makes that true -- so it has to
  # still be a select, still carry every option, and still post under the name the route
  # reads. A hidden input would pass "the value is on the page" and fail this.
  it 'still offers every movement as a menu that posts on its own' do
    get "/workouts/#{@workout}/sets/new"

    assert_includes last_response.body, '<select id="exercise_id" name="exercise_id"'
    assert_includes last_response.body, '<optgroup label="Library">'
    assert_includes last_response.body, 'Bent Over Row'
  end

  # And the half #525 must not break, which _exercise_options exists to say: a menu with
  # nothing marked submits its first option, so an edit form that forgot its selection would
  # move the set to whichever movement sorts first.
  it 'still marks the movement the set is already on' do
    get "/workouts/#{@workout}/sets/#{@set}/edit"

    assert_includes last_response.body, %(<option value="#{@exercise}" selected>)
  end
end

describe 'searching the movement list' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_new_set_form }

  # The bug, in one assertion. Eighty-odd movements on a phone is a scroll wheel with
  # eighty-odd detents, spun with a thumb between sets; four letters is the feature.
  it 'narrows the list to the movements that match' do
    type 'row'

    assert_equal (FindingAMovement::LIBRARY_ROWS + [FindingAMovement::OWN_ROW]).sort, offered.sort
  end

  # Terms in any order, and none of them has to start a word. This is the search the issue is
  # actually about: the name a lifter reaches for is "db row", and the movement is filed
  # under "Single-Arm".
  it 'matches on any part of the name, in any order' do
    type 'db row'

    assert_equal [FindingAMovement::OWN_ROW], offered
  end

  # Asserted through the element rather than through assert_text, and every claim in this
  # file about something not being on screen is, for a reason worth writing down: Capybara's
  # page-level text assertions ask Selenium for the rendered text of <html>, and Firefox
  # answers that one out of textContent -- so a paragraph inside a display:none popup reads
  # as visible, and refute_text then passes or fails for reasons that have nothing to do
  # with the page. A selector is resolved per element through the driver's own visibility
  # test, which is the question actually being asked.
  it 'says so when nothing matches rather than showing an empty box' do
    type 'kettlebell'

    assert_empty offered
    assert_selector '[data-picker-empty]', text: 'No movement matches that.'
  end
end

describe 'telling the library from your own movements' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_new_set_form }

  # The distinction is real information rather than decoration -- "is this the library Bent
  # Over Row or the one I named myself" is the question somebody goes looking with -- so it
  # survives into the results rather than being a property of the unfiltered menu.
  it 'says which results are the library and which are yours' do
    type 'row'

    assert_equal ['Library', 'Your exercises'], headings
  end

  # And a heading with nothing under it goes with its group. A "Library" label over an empty
  # space is a list claiming to have matched something.
  it 'drops a group that has nothing matching in it' do
    type 'db row'

    assert_equal ['Your exercises'], headings
  end
end

describe 'picking a movement from the keyboard' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_new_set_form }

  # The shortest path there is, and the one a phone keyboard's Done key takes: the top match
  # is already under the cursor by the time the typing stops, so Enter commits it without an
  # arrow being pressed at all. That is the APG's automatic-selection combobox, and here it
  # is the difference between four letters and four letters plus aiming a thumb at a row.
  it 'commits the top match on Enter' do
    type 'db row'
    search_box.send_keys(:enter)

    assert_equal FindingAMovement::OWN_ROW, search_box.value
    assert_equal @own[FindingAMovement::OWN_ROW].to_s, submitted_exercise_id
  end

  # And the arrows walk on from there.
  #
  # Which movement that lands on is read off the list rather than named here. It used to be
  # named -- 'Pendlay Row', the second of four library rows in insertion order -- and #551
  # sorting the list alphabetically made it 'Landmine Row', which is a fact about the order
  # and not about the arrow key this spec is here for. Written down, the name would have to
  # be rewritten by hand every time the order moved; read off the page, the claim is the one
  # actually being made: one press of Down goes to whatever the list is showing second, and
  # the select underneath follows it. The order itself is pinned in
  # spec/the_order_movements_are_listed_in_spec.rb, which is where an argument about it
  # belongs.
  it 'walks past it with the arrows' do
    type 'row'
    second_name, second_id = offered_row(1)
    search_box.send_keys(:arrow_down, :enter)

    assert_equal second_name, search_box.value
    assert_equal second_id, submitted_exercise_id
  end

  # Nothing matching means nothing to commit, so Enter closes rather than doing nothing at
  # all -- which would leave a lifter inside a list standing over the rest of the form with
  # no way out but a key a phone keyboard does not have.
  it 'closes on Enter when nothing matched' do
    type 'kettlebell'
    search_box.send_keys(:enter)

    assert_equal 'false', search_box[:'aria-expanded']
    refute_selector '[data-picker-empty]'
  end
end

describe 'what the movement search says out loud' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_new_set_form }

  # The list shortening is a visual event, and this form has a reader on it too. Same answer
  # and same politeness as the session screen's announcements (#336).
  it 'reads the number of results out' do
    type 'db row'

    assert_selector '[data-picker-announce]', visible: :all, text: '1 movement'
  end

  # Focus never leaves the text box while the list is walked -- the cursor is
  # aria-activedescendant -- which is what keeps this from being the eighty-four Tab stops a
  # listbox of focusable options would be, and what a reader follows instead of focus.
  it 'points the reader at the row the cursor is on' do
    type 'db row'
    row = find('#exercise-listbox [role="option"]')

    assert_equal row[:id], search_box[:'aria-activedescendant']
    assert_equal 'true', search_box[:'aria-expanded']
  end
end

describe 'the edit form opening on the movement the set is on' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_set_to_edit }

  # What _exercise_options has always guaranteed, now that the thing on screen is a text box
  # rather than the menu: the set is on Cable Fly, so that is the name in the box and that is
  # the id underneath it -- not the first movement in the list.
  it 'opens on the movement the set is on' do
    assert_equal 'Cable Fly', search_box.value
    assert_equal @own['Cable Fly'].to_s, submitted_exercise_id
  end

  # The case nobody thinks to test and everybody does: a lifter here to fix a weight, who
  # never touches the picker at all. The set must not move.
  #
  # The refute is the premise rather than the point, and it is here because without it this
  # spec would pass on a picker that had forgotten its selection entirely: a form that posts
  # its first movement is indistinguishable from one that posts the right one, on a set that
  # happens to be on the first movement. sets_spec makes the same argument at length.
  it 'saves the set on the same movement when the picker is never touched' do
    refute_equal first_movement, @own['Cable Fly']

    fill_in 'weight', with: '45'
    click_button 'Save'

    assert_equal @own['Cable Fly'], exercise_on(@set_id)
    assert_equal 45, DB[:sets].where(id: @set_id).get(:weight)
  end
end

describe 'changing the movement a set is on' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  before { a_set_to_edit }

  # Escape is the way out of a picker opened by accident, and on this form it is the
  # difference between a typo and a set filed under the wrong lift.
  it 'puts the movement back when Escape closes the list' do
    type 'row'
    search_box.send_keys(:escape)

    assert_equal 'Cable Fly', search_box.value
    assert_equal @own['Cable Fly'].to_s, submitted_exercise_id
  end

  # Half-typed and abandoned is not a choice. The box is a search field and the select is the
  # answer, so anything left lying in it goes when focus does -- here by Tab, which is what
  # moving on to the weight without answering looks like from a keyboard.
  it 'ignores a search nobody finished' do
    type 'sing'
    search_box.send_keys(:tab)
    click_button 'Save'

    assert_equal @own['Cable Fly'], exercise_on(@set_id)
  end

  it 'moves the set when a movement is actually chosen' do
    type 'db row'
    find('#exercise-listbox [role="option"]', text: FindingAMovement::OWN_ROW).click
    click_button 'Save'

    assert_equal @own[FindingAMovement::OWN_ROW], exercise_on(@set_id)
  end
end

describe 'logging a new set through the search box' do
  include Capybara::DSL
  include Minitest::Capybara::Behaviour
  include BrowserSpec
  include FindingAMovement

  # The untouched new-set form used to post the menu's first option, and that was #631: a
  # lifter who typed a weight and saved had logged Anderson Squat, the first movement
  # alphabetically. On an account with nothing logged the picker now starts on no movement at
  # all, so not answering writes nothing and the form asks for one. The search box must not
  # change that either -- it is still what a lifter gets by not answering.
  it 'logs nothing, and asks for a movement, when the picker is never touched' do
    a_new_set_form
    fill_in 'weight', with: '135'
    fill_in 'reps', with: '5'
    click_button 'Save'

    assert_nil DB[:sets].where(workout_id: @workout_id).get(:exercise_id)
    assert_text 'Choose a movement for the set'
  end

  it 'logs against the movement the search found' do
    a_new_set_form
    type 'db row'
    find('#exercise-listbox [role="option"]', text: FindingAMovement::OWN_ROW).click
    fill_in 'weight', with: '55'
    fill_in 'reps', with: '10'
    click_button 'Save'

    assert_equal @own[FindingAMovement::OWN_ROW], DB[:sets].where(workout_id: @workout_id).get(:exercise_id)
  end
end

