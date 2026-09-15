# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'dumbbell_rack_spec'   # and its rack helpers
require 'securerandom'

# The settings page says which number it wants, and says back what it understood. #439.
#
# Every field on that form is ambiguous in the same way. "Handle" could be one handle or the
# pair; "four 2.5 lb plates" could be four plates or four pairs. The two readings differ by a
# factor of two, which is enough to make every generated weight wrong -- and nothing anywhere
# afterwards would have looked any different, because a wrong rack produces weights that are
# perfectly plausible and simply not loadable.
#
# The echo is a range rather than a restatement of what was typed, which is the stronger check:
# it is derived through the same enumeration the generator prescribes from, so a lifter who
# read "pairs" as "plates" sees a top end twice what their rack can do. Restating the input
# would only prove the app can echo.
module EquipmentEcho
  include DumbbellRack

  def settings_for(account_id)
    the_rack(account_id)
    get '/settings'
    last_response.body.gsub(/\s+/, ' ')
  end

  # The reporting account's shelf: a 4 lb handle with pairs of 10, 5 and 2.5, and a barbell
  # rack with one pair each of the big plates.
  def the_rack(account_id)
    DB[:accounts].where(id: account_id).update(bar_weight: 45, dumbbell_handle_weight: 4)
    { 45 => 1, 25 => 1, 10 => 1, 5 => 2, 2.5 => 2 }.each do |denomination, pairs|
      DB[:account_plates].insert(account_id:, denomination:, pairs:)
    end
    { 10 => 2, 5 => 2, 2.5 => 3 }.each do |denomination, pairs|
      DB[:account_dumbbell_plates].insert(account_id:, denomination:, pairs:)
    end
  end
end

describe 'what the equipment form asks for' do
  include Rack::Test::Methods
  include RouteOwnership
  include EquipmentEcho

  before { @said = settings_for(login) }

  # "Handle" was the worst of them and the issue names it: ambiguous between one and the pair.
  it 'names which handle it means' do
    assert_includes @said, 'One handle, with nothing on it'
  end

  it 'names the bar as the empty bar' do
    assert_includes @said, 'The empty bar, on its own'
  end

  # The echo the issue asks for, in the issue's own words: "4 lb each, 8 lb for the pair."
  it 'says the handle weight back both ways' do
    assert_includes @said, '4 lb</span> each, 8 lb for the pair'
  end
end

describe 'what the equipment form says it understood' do
  include Rack::Test::Methods
  include RouteOwnership
  include EquipmentEcho

  before { @said = settings_for(login) }

  # One pair each of 45, 25 and 10 with two of 5 and 2.5 reaches 45 + 2 * 95.
  it 'says what the bar loads' do
    assert_includes @said, 'That loads <span class="font-semibold text-gray-900">45 lb to 235 lb</span>'
  end

  # Both dumbbell answers, which is the shortest explanation of a thing that would otherwise
  # look like a bug: a dumbbell bench prescribed lighter than a single-arm row off the same
  # plates. #439 and #467 between them.
  it 'says what one dumbbell loads and what a pair loads' do
    assert_includes @said, 'One dumbbell loads <span class="font-semibold text-gray-900">4 lb to 79 lb</span>'
    assert_includes @said, 'A matched pair loads <span class="font-semibold text-gray-900">4 lb to 39 lb</span> each'
  end
end

# Nothing to echo is not an error, and this is the ordinary case: most accounts have a fixed
# dumbbell rack and have never filled the second half of the form in.
describe 'an account that has said nothing about its dumbbells' do
  include Rack::Test::Methods
  include RouteOwnership
  include EquipmentEcho

  it 'says nothing about what they load rather than inventing a range' do
    login
    get '/settings'
    said = last_response.body.gsub(/\s+/, ' ')

    refute_includes said, 'One dumbbell loads'
    refute_includes said, 'for the pair'
  end
end

