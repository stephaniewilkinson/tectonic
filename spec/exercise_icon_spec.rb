# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/exercise_library'

# The picture beside a lift on the workout record. Every lift used to draw the same one --
# a figure holding a dumbbell, in an app that models only the bar -- so what these assert
# is that two movements draw two different things, and that what the alt says is what the
# file draws.
module ExerciseIcon
  def app
    Tectonic.app
  end

  # A logged-in account with an empty record to hang lifts on.
  def start_a_record
    @account_id = login
    @workout_id = DB[:workouts].insert(account_id: @account_id, date: Time.now)
  end

  # A movement with a set of it on the record, a set being the only thing that puts a
  # movement on this page.
  def log(name, icon_url: nil)
    exercise_id = DB[:exercises].insert(name:, account_id: @account_id, icon_url:)
    DB[:sets].insert(workout_id: @workout_id, exercise_id:, weight: 100, reps: 5,
                     is_warmup: false, is_completed: true)
    exercise_id
  end

  def record
    get "/workouts/#{@workout_id}"
    last_response.body
  end
end

describe 'the icon a movement draws on the workout record' do
  include Rack::Test::Methods
  include RouteOwnership
  include ExerciseIcon

  before { start_a_record }

  it 'draws each movement rather than one figure for all of them' do
    log 'Low-Bar Squat'
    log 'Pendlay Row'

    body = record

    assert_includes body, '<img src="/icons/squat.svg" alt="Squat icon"'
    assert_includes body, '<img src="/icons/row.svg" alt="Barbell row icon"'
  end

  # The three names that disagreed: the file said mommy-fitness, the alt said plank, and
  # the credit on /about said benchpress.
  it 'has stopped drawing the dumbbell figure and calling it a plank' do
    log 'Back Squat'

    body = record

    refute_includes body, 'mommy-fitness'
    refute_includes body, 'Plank icon'
  end

  # Twenty-three of the built-in fifty-four land here, the olympic lifts and every press
  # that is not a bench press among them. A barbell is the honest thing to draw for them.
  it 'falls back to a barbell for a movement none of the five icons draws' do
    log 'Power Clean'

    assert_includes record, '<img src="/icons/gym.svg" alt="Barbell icon"'
  end
end

# icon_url was on the exercise form from the beginning. #199 took the field off it: since
# #171 every movement draws a shipped icon, so the field's only remaining job was to point
# every visitor's browser at a third party to override a default that works. The column and
# the override live on -- the MCP tools write it, and rows written through the old form
# still carry values -- so what is drawn is still tested here.
describe 'an icon the account chose for itself' do
  include Rack::Test::Methods
  include RouteOwnership
  include ExerciseIcon

  before { start_a_record }

  it 'is drawn in place of the one the name would have picked' do
    log 'Barbell Curl', icon_url: 'https://example.com/curl.png'

    assert_includes record, '<img src="https://example.com/curl.png" alt="Barbell Curl icon"'
  end

  # The old form posted the field whether or not anyone typed in it, so rows created
  # through it carry an empty string rather than a null, and an empty src is a broken image
  # on every card. Those rows outlive the field, and an MCP tool can still send one.
  it 'counts a field left blank as no icon at all' do
    log 'Barbell Curl', icon_url: ''

    body = record

    assert_includes body, '/icons/gym.svg'
    refute_includes body, 'src=""'
  end

  # Nothing checks the column on the way in, so the check is here, where the value becomes
  # a src. A javascript: URL is inert in an img and #121 keeps it inside the attribute, so
  # this refuses a value that could never be a picture rather than closing a hole.
  it 'is refused when it could never be an image' do
    log 'Barbell Curl', icon_url: 'javascript:alert(1)'

    body = record

    assert_includes body, '/icons/gym.svg'
    refute_includes body, 'javascript:alert'
  end
end

# #199 asked the field to go and the column to stay. The gap between those two is the thing
# worth a test: the route used to read r.params['icon_url'] on the way past, and a form that
# no longer sends one would have handed it a nil. Renaming a movement in the browser would
# then have wiped an icon an assistant chose, with nothing on the page to say a picture had
# been part of what was saved.
describe 'a movement whose icon was set by something other than the form' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @account_id = login }

  it 'is not offered the field on the form' do
    get '/exercises/new'

    refute_includes last_response.body, 'name="icon_url"'
  end

  it 'keeps the icon when the movement is edited in the browser' do
    id = DB[:exercises].insert(name: 'Zercher Squat', account_id: @account_id,
                               icon_url: 'https://example.com/zercher.png')

    post '/exercises', { id: id.to_s, name: 'Zercher Squat (belt)', note: '',
                         '_csrf' => token_for('/exercises/new') }

    assert_equal 'Zercher Squat (belt)', DB[:exercises].where(id:).get(:name)
    assert_equal 'https://example.com/zercher.png', DB[:exercises].where(id:).get(:icon_url)
  end
end

describe 'the files the icon tables name' do
  include Rack::Test::Methods
  include ExerciseIcon

  # A misspelt filename in the table is a broken image on the record and nothing else --
  # no error, no log line -- so the tables are checked against what the app will serve.
  it 'are all served' do
    (Tectonic::Exercise::ICONS.values + [Tectonic::Exercise::GENERIC_ICON]).each do |icon|
      get icon[:src]

      assert_equal 200, last_response.status, icon[:src]
      assert_includes last_response.headers['content-type'], 'image/svg+xml'
    end
  end
end

# Noun Project's licence turns on the credit naming the work in use. It named a benchpress
# icon while the app drew a dumbbell figure: a credit for a file nobody was served, and no
# credit for the file everybody was.
describe 'the acknowledgement on /about' do
  include Rack::Test::Methods
  include ExerciseIcon

  before { get '/about' }

  it 'names the icons the app actually draws' do
    assert_includes last_response.body,
                    'Squat, deadlift, benchpress, row, pull-up and barbell icons by Sebastian Schuldt'
  end
end

