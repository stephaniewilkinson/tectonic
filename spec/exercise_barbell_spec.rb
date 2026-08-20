# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative '../lib/tectonic/exercise_library'
require 'securerandom'

# A movement whose name the library has never heard of, which is the whole point: while
# the flag was derived from the name, a variation somebody invented could not be a barbell
# lift however it was written down.
def invented_name
  "Front Squat Variation #{SecureRandom.hex(4)}"
end

describe 'creating a movement through the form' do
  include Rack::Test::Methods
  include RouteOwnership

  before { @account_id = login }

  it 'takes the barbell answer from the person filling it in' do
    post '/exercises', { 'name' => invented_name, 'icon_url' => '', 'id' => '',
                         'is_barbell' => '1', '_csrf' => token_for('/exercises/new') }
    assert Tectonic::Exercise.where(account_id: @account_id).order(:id).last.barbell?
  end

  it 'leaves it off when the box is not ticked' do
    post '/exercises', { 'name' => invented_name, 'icon_url' => '', 'id' => '',
                         '_csrf' => token_for('/exercises/new') }
    refute Tectonic::Exercise.where(account_id: @account_id).order(:id).last.barbell?
  end

  # The gap the column exists to close: plate math for a movement the library cannot name.
  it 'gives its sets the plate breakdown a set of a library movement gets' do
    post '/exercises', { 'name' => invented_name, 'icon_url' => '', 'id' => '',
                         'is_barbell' => '1', '_csrf' => token_for('/exercises/new') }
    exercise = Tectonic::Exercise.where(account_id: @account_id).order(:id).last
    workout_id = own_workout(@account_id)
    path = "/workouts/#{workout_id}/sets/new"
    post path, { 'weight' => '135', 'reps' => '5', 'exercise_id' => exercise.id.to_s,
                 '_csrf' => token_for(path) }

    get "/workouts/#{workout_id}/session"
    assert_includes last_response.body.dup.force_encoding(Encoding::UTF_8), 'per side 1×45'
  end
end

describe 'a movement created with nobody to ask' do
  it 'is a barbell lift when the library knows the name' do
    account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    known = Tectonic::Exercise.create(account_id:, name: 'Bench Press',
                                      is_barbell: Tectonic::Exercise.barbell_by_name?('Bench Press'))
    assert known.barbell?
    refute Tectonic::Exercise.barbell_by_name?(invented_name)
  end

  it 'loads the built-in library already marked, so a fresh database needs no backfill' do
    Tectonic::Exercise.load_library
    assert Tectonic::Exercise.where(account_id: nil, name: 'Back Squat').first.barbell?
    assert_equal 0, Tectonic::Exercise.where(account_id: nil, is_barbell: false).count
  end
end

