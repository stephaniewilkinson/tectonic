# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and token minting and call_tool
require_relative '../lib/tectonic/rests'
require 'securerandom'

# A rest a lifter can name on the movements they actually train. #456, and 039.
#
# 037 put `default_rest_seconds` on `exercises` and argued the right thing for the wrong
# object. Its rule stands -- the bell rings only on a length somebody named, because a
# countdown that rings unasked is the app deciding how long a lifter rests. What it got wrong
# is where the naming lives.
#
# A library movement has a null account_id and sits on every account's page, so `Exercise`
# refuses an edit to one. That is correct and it made the field unsettable for **nine of the
# thirty-three movements the reporting account trains** -- Back Squat, Bench Press, Front
# Squat, Overhead Press, Decline Bench Press, Good Morning, Barbell Hip Thrust, Deficit
# Deadlift and Power Snatch. Two of the three main lifts. So the bell could be switched on for
# banded clamshells and never for squats, which is the opposite of where three minutes matters.
#
# 020 had already solved this exact problem for the training max: keyed on (account, movement),
# the value is private by construction and a shared Back Squat carries a different one for
# every account that lifts it.
module BellForTheLifter
  # A real seeded library row rather than one written here: a nil account_id is how the library
  # is spelled, so CleanDatabase deliberately keeps them and an invented one would outlive the
  # run that made it.
  def a_library_movement
    Tectonic::Exercise.where(account_id: nil).order(:id).first ||
      raise('the seeded library is missing; run rake library:exercises against the test database')
  end

  def rest_for(account_id, exercise)
    Tectonic::Rest.for(account_id:, exercise_id: exercise.id)
  end
end

describe 'naming a rest on a movement nobody owns' do
  include Rack::Test::Methods
  include RouteOwnership
  include BellForTheLifter

  before do
    @account_id = login
    @squat = a_library_movement
  end

  def save(seconds)
    post "/exercises/#{@squat.id}/rest",
         { 'seconds' => seconds,
           '_csrf' => token_for_form("/exercises/#{@squat.id}/", "/exercises/#{@squat.id}/rest") }
  end

  # The whole of the fix. Before 039 this was unsayable, and it is the case the feature exists
  # for: the lifts where three minutes is the difference between a working set and a miss.
  it 'records it' do
    save('180')

    assert_equal 180, rest_for(@account_id, @squat)
  end

  it 'offers the field on the page' do
    get "/exercises/#{@squat.id}/"

    assert_includes last_response.body, 'name="seconds"'
  end
end

# The two ways a rest comes back off, which have to keep working on a shared movement exactly
# as they do on an owned one.
describe 'unsaying a rest on a movement nobody owns' do
  include Rack::Test::Methods
  include RouteOwnership
  include BellForTheLifter

  before do
    @account_id = login
    @squat = a_library_movement
  end

  def save(seconds)
    post "/exercises/#{@squat.id}/rest",
         { 'seconds' => seconds,
           '_csrf' => token_for_form("/exercises/#{@squat.id}/", "/exercises/#{@squat.id}/rest") }
  end

  # Blank clears, which is the way back from having named one. Without it the answer would be
  # unsayable once said.
  it 'takes a blank as no bell' do
    save('180')
    save('')

    assert_nil rest_for(@account_id, @squat)
  end

  # Refused rather than clamped, on Rest.clean's terms: clamping 9000 to 1800 would store a
  # number nobody typed and then ring at them for half an hour of it.
  it 'refuses a rest nobody would take' do
    save('9000')

    assert_nil rest_for(@account_id, @squat)
  end
end

# The reason the table exists rather than the column, stated as a test: the same shared
# movement holds a different answer for each lifter, and neither can read the other's.
describe 'two lifters on one shared movement' do
  include Rack::Test::Methods
  include RouteOwnership
  include BellForTheLifter

  it 'keeps each rest to the lifter who named it' do
    squat = a_library_movement
    mine = login
    Tectonic::Rest.replace(mine, squat.id, 180)
    theirs = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    Tectonic::Rest.replace(theirs, squat.id, 90)

    assert_equal 180, rest_for(mine, squat)
    assert_equal 90, rest_for(theirs, squat)
  end

  it 'says nothing to a lifter who has not named one' do
    squat = a_library_movement
    Tectonic::Rest.replace(login, squat.id, 180)

    assert_nil rest_for(DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x'), squat)
  end
end

# And the connector, which has to draw the same line: the rest is the lifter's, everything else
# on the row belongs to the movement and stays owner-only.
describe 'setting a shared movement rest through the tools' do
  include Rack::Test::Methods
  include BellForTheLifter

  before do
    @token = mint(scopes: %w[read write])
    @squat = a_library_movement
  end

  it 'lets an assistant name the rest' do
    call_tool('update_exercise', raw: @token.raw,
                                 arguments: { exercise_id: @squat.id, default_rest_seconds: 180 })

    assert_equal 180, rest_for(@token.account_id, @squat)
  end

  it 'still refuses to rename it' do
    call_tool('update_exercise', raw: @token.raw,
                                 arguments: { exercise_id: @squat.id, name: 'Not Your Squat' })

    assert tool_result['isError']
    refute_equal 'Not Your Squat', Tectonic::Exercise[@squat.id].name
  end

  # The refusal says what *is* possible, which is the difference between a model trying
  # something else and a model trying the same call again.
  it 'names the rest as the thing it could have set' do
    call_tool('update_exercise', raw: @token.raw,
                                 arguments: { exercise_id: @squat.id, name: 'Not Your Squat' })

    assert_includes tool_result.dig('content', 0, 'text'), 'rest'
  end
end

