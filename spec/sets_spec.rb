# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'

# The set write routes driven through the forms that feed them. Every bug covered
# here is a disagreement between what a form renders and what its route reads, so a
# test posting a hand-built hash would miss all of them: the form is opened and
# submitted back the way a browser submits it, changing only the field a user came
# to change.
module SetForm
  # What a browser would post for the form in `body`. A text field sends its value, a
  # checkbox sends nothing at all unless it is ticked, and a menu sends its selected
  # option -- or its first, when nothing is marked, which is how an unmarked menu
  # rewrites the row it was supposed to be showing.
  def submitted(body, overrides = {})
    fields = { '_csrf' => token_from(body), 'exercise_id' => menu_choice(body),
               'weight' => value_of(body, 'weight'), 'reps' => value_of(body, 'reps') }
    ticked(body).each { |name| fields[name] = 'on' }
    fields.merge(overrides)
  end

  # Opens a set's edit form and posts it straight back, altered only by `overrides`.
  def save_form(workout, set, overrides = {})
    get "/workouts/#{workout}/sets/#{set}/edit"
    post "/workouts/#{workout}/sets/#{set}", submitted(last_response.body, overrides)
  end

  # Logs a set through the new-set form's route and returns the row it wrote.
  def log_set(workout, exercise_id, weight)
    path = "/workouts/#{workout}/sets/new"
    post path, { weight: weight.to_s, reps: '5', exercise_id: exercise_id.to_s, '_csrf' => token_for(path) }
    DB[:sets].where(workout_id: workout).order(:id).last
  end

  def value_of(body, name)
    field(body, name)[/value="([^"]*)"/, 1]
  end

  def ticked(body)
    %w[is_completed is_warmup].select { |name| field(body, name).include?('checked') }
  end

  def field(body, name)
    body[/<input[^>]*name="#{name}"[^>]*>/]
  end

  def menu_choice(body)
    options = body.scan(/<option[^>]*>/)
    (options.find { |option| option.include?('selected') } || options.first)[/value="([^"]*)"/, 1]
  end

  def own_exercise(account_id, name)
    DB[:exercises].insert(name: "#{name} #{SecureRandom.hex(4)}", account_id:)
  end

  # A private movement belonging to someone else, which no set of this account's may
  # be pointed at however the form is filled in.
  def strangers_exercise
    email, = make_account
    own_exercise(DB[:accounts].where(email:).get(:id), 'Secret')
  end

  # A signed-in account with a workout, two movements, and a completed warmup set on
  # the second of them -- second so that the first option of the exercise menu is
  # never the one the set is already on, and an unmarked menu shows up as a move.
  def account_with_a_logged_set
    account_id = login
    workout = own_workout(account_id)
    other = own_exercise(account_id, 'Machine Row')
    exercise = own_exercise(account_id, 'Cable Fly')
    set = DB[:sets].insert(workout_id: workout, exercise_id: exercise, weight: 100, reps: 5,
                           is_warmup: true, is_completed: true)
    [workout, set, exercise, other]
  end
end

describe 'saving the set edit form' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetForm

  before { @workout, @set, @exercise, = account_with_a_logged_set }

  it 'leaves a completed warmup set completed when only the weight changed' do
    save_form(@workout, @set, 'weight' => '105')

    row = DB[:sets].where(id: @set).first
    assert_equal 105, row[:weight]
    assert row[:is_completed]
    assert row[:is_warmup]
  end

  it 'leaves the set on the movement it was already on' do
    save_form(@workout, @set, 'weight' => '105')

    assert_equal @exercise, DB[:sets].where(id: @set).get(:exercise_id)
  end
end

# Both forms are one partial now, and this is the difference it keeps: logging a set with
# neither a weight nor a rep count records nothing, so the new-set form makes the browser
# say so before it posts. Whether saving an existing row may empty those fields is a
# separate question that the edit form has never asked, and merging is not the moment to
# start -- so the flag has to follow which form is on screen, not the markup they share.
describe 'the fields the set forms insist on' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetForm

  before { @workout, @set, = account_with_a_logged_set }

  it 'asks the new-set form for a weight and a rep count' do
    get "/workouts/#{@workout}/sets/new"

    assert_includes field(last_response.body, 'weight'), 'required'
    assert_includes field(last_response.body, 'reps'), 'required'
  end

  it 'asks the edit form for neither, which is saving a row that has both already' do
    get "/workouts/#{@workout}/sets/#{@set}/edit"

    refute_includes field(last_response.body, 'weight'), 'required'
    refute_includes field(last_response.body, 'reps'), 'required'
  end
end

describe 'substituting the exercise on a set' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetForm

  before { @workout, @set, @exercise, @other = account_with_a_logged_set }

  it 'moves the set to the movement the menu chose' do
    save_form(@workout, @set, 'exercise_id' => @other.to_s)

    assert_equal @other, DB[:sets].where(id: @set).get(:exercise_id)
  end

  it 'refuses a movement this account cannot select' do
    save_form(@workout, @set, 'exercise_id' => strangers_exercise.to_s)

    assert_equal @exercise, DB[:sets].where(id: @set).get(:exercise_id)
  end

  it 'is reachable from the workout page, which is the only route to it' do
    get "/workouts/#{@workout}"

    assert_includes last_response.body, "/workouts/#{@workout}/sets/#{@set}/edit"
  end
end

# Plate math is what this app is for, and it renders only for a set that knows it is
# loaded on a bar. That flag used to arrive from the program generator alone, so a
# lift logged by hand -- the way most sets are logged -- never got one.
describe 'plate math for a set logged by hand' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetForm

  before do
    Tectonic::Exercise.load_library
    @account_id = login
    @workout = own_workout(@account_id)
    @squat = Tectonic::Exercise.where(account_id: nil, name: 'Back Squat').get(:id)
  end

  # The line used to be headed "per side", which this app spends on a rep count taken per
  # side; it is headed "Plate math" now, and the heading and the breakdown are asserted
  # apart because the markup puts them in separate elements.
  it 'breaks a barbell lift down plate by plate in the session view' do
    assert log_set(@workout, @squat, 135)[:is_barbell]

    get "/workouts/#{@workout}/session"
    body = last_response.body.dup.force_encoding(Encoding::UTF_8)

    assert_includes body, 'Plate math'
    assert_includes body, '1×45'
  end

  it 'says nothing about plates for a movement that is not loaded on a bar' do
    refute log_set(@workout, own_exercise(@account_id, 'Cable Fly'), 40)[:is_barbell]
  end

  # A substituted set has to take the new movement's plate math with it: the label is
  # computed from a flag on the row, so a stale one goes on describing the lift that
  # was swapped out.
  it 'follows the movement when the set is moved onto a barbell lift' do
    set = log_set(@workout, own_exercise(@account_id, 'Cable Fly'), 40)[:id]
    save_form(@workout, set, 'exercise_id' => @squat.to_s, 'weight' => '135')

    assert DB[:sets].where(id: set).get(:is_barbell)
  end
end

