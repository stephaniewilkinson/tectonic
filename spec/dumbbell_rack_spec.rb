# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative '../lib/tectonic/equipment'
require 'securerandom'

# Dumbbells are their own rack. #369.
#
# 007 asked an account what plates it owns, and every weight this app writes has been rounded
# to what that rack can build ever since. It asked about one rack, and most people who train at
# home have two.
#
# What stood in for the second was `DUMBBELL_INCREMENT`, a constant of 5, which #259 was honest
# about calling an assumption. It is right for a fixed rack and wrong in both directions for an
# adjustable set: a pair of Powerblocks steps in 2.5 at the bottom, so 27.5 is loadable and was
# being rounded away; and a handle with only 5s and 10s on the shelf cannot make 22.5, which
# the assumption cheerfully prescribed.
module DumbbellRack
  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')

  def with_dumbbells(account_id, handle:, plates:)
    DB[:accounts].where(id: account_id).update(dumbbell_handle_weight: handle)
    plates.each do |denomination, pairs|
      DB[:account_dumbbell_plates].insert(account_id:, denomination:, pairs:)
    end
    Tectonic::Equipment.for_account(account_id)
  end
end

# Nothing changes for anybody until they fill the form in, which is the promise 007 made about
# the barbell rack and the one 033 makes about this one.
describe 'an account that has said nothing about its dumbbells' do
  include DumbbellRack

  it 'is described by the assumption, exactly as before' do
    equipment = Tectonic::Equipment.for_account(an_account)

    refute equipment.adjustable_dumbbells?
    assert_equal Tectonic::Equipment::DUMBBELL_INCREMENT, equipment.dumbbell_increment
  end

  it 'still rounds a dumbbell prescription to fives' do
    equipment = Tectonic::Equipment.for_account(an_account)

    assert_equal 25, equipment.loadable(27, is_barbell: false)
  end

  # The barbell's micro plates have nothing to do with the dumbbells, which is the bug #259
  # guarded against with the constant: a pair of 1 lb plates takes the bar's increment to 2,
  # and 26 lb dumbbells are not a thing most gyms have.
  it 'is not dragged down by the plates on the bar' do
    account_id = an_account
    DB[:account_plates].insert(account_id:, denomination: 1, pairs: 1)

    assert_equal 5, Tectonic::Equipment.for_account(account_id).dumbbell_increment
  end
end

describe 'an account with adjustable dumbbells' do
  include DumbbellRack

  # A 5 lb handle with 2.5s on it steps in fives at the top and reaches 10 at the bottom.
  it 'takes its increment from its own smallest plate' do
    equipment = with_dumbbells(an_account, handle: 5, plates: { 2.5 => 2, 5 => 2 })

    assert equipment.adjustable_dumbbells?
    assert_equal 5, equipment.dumbbell_increment
  end

  # The half of the assumption that was rounding real weights away.
  #
  # `dumbbells: 1` is explicit since #439, and these three say it because they are about the
  # rack's arithmetic rather than about any movement: a shelf is described by what one handle
  # can take, which is 033's rule for what `pairs` counts. The default is two, so leaving it
  # off here would quietly be asking a different question -- how far the same shelf goes when
  # it has to furnish two handles at once -- and the answers below are the one-handle ones.
  it 'can load a weight the assumption refused' do
    equipment = with_dumbbells(an_account, handle: 5, plates: { 1.25 => 2, 2.5 => 2, 5 => 2 })

    assert_equal 27.5, equipment.loadable(27.5, is_barbell: false, dumbbells: 1)
  end

  # And the half that was prescribing weights nobody could make: a handle with only 5s and
  # 10s cannot reach 22.5, whatever an increment of 5 says.
  it 'refuses a weight its own plates cannot build' do
    equipment = with_dumbbells(an_account, handle: 5, plates: { 5 => 2, 10 => 2 })

    refute_equal 22.5, equipment.loadable(22.5, is_barbell: false, dumbbells: 1)
    assert_includes equipment.dumbbell_totals(1), equipment.loadable(22.5, is_barbell: false, dumbbells: 1)
  end

  # Plates go on both ends, so a pair adds twice its denomination -- the same arithmetic a
  # barbell uses, which is why one enumeration answers for both racks.
  it 'counts a pair as one plate on each end' do
    equipment = with_dumbbells(an_account, handle: 10, plates: { 5 => 1 })

    assert_equal [10, 20], equipment.dumbbell_totals(1).sort
  end

  # The barbell rack is untouched by any of this. Two inventories that could reach into one
  # another would be worse than one.
  it 'leaves the barbell alone' do
    equipment = with_dumbbells(an_account, handle: 5, plates: { 1.25 => 4 })

    assert_equal Tectonic::Equipment::DEFAULT_BAR, equipment.bar_weight
    assert_equal 5, equipment.increment
  end
end

# Neither half is any use alone: a handle with no plates loads nothing, and plates with no
# handle have nothing to go on. An account that has filled in one and not the other is
# describing a rack that does not exist, and the honest reading is the fixed one.
describe 'a dumbbell rack described by halves' do
  include DumbbellRack

  it 'falls back to the assumption with a handle and no plates' do
    equipment = with_dumbbells(an_account, handle: 5, plates: {})

    refute equipment.adjustable_dumbbells?
    assert_equal Tectonic::Equipment::DUMBBELL_INCREMENT, equipment.dumbbell_increment
  end

  it 'falls back to the assumption with plates and no handle' do
    equipment = with_dumbbells(an_account, handle: nil, plates: { 2.5 => 2 })

    refute equipment.adjustable_dumbbells?
    assert_equal Tectonic::Equipment::DUMBBELL_INCREMENT, equipment.dumbbell_increment
  end
end

describe 'the settings form' do
  include Rack::Test::Methods
  include RouteOwnership
  include DumbbellRack

  it 'saves both racks in one submission' do
    account_id = login

    post '/settings', { bar_weight: '45', plates: { '45' => '2' },
                        dumbbell_handle_weight: '5', dumbbell_plates: { '2.5' => '4' },
                        '_csrf' => token_for_form('/settings', '/settings') }

    equipment = Tectonic::Equipment.for_account(account_id)

    assert_equal 5, equipment.dumbbell_handle_weight
    assert_equal({ 2.5 => 4 }, equipment.dumbbell_pairs)
    assert_equal({ 45 => 2 }, equipment.pairs)
  end

  # The way back from having described adjustable dumbbells, which without this would be
  # unsayable once it had been said.
  it 'returns an account to a fixed rack when the handle is cleared' do
    account_id = login
    with_dumbbells(account_id, handle: 5, plates: { 2.5 => 4 })

    post '/settings', { bar_weight: '45', plates: { '45' => '2' },
                        dumbbell_handle_weight: '', dumbbell_plates: {},
                        '_csrf' => token_for_form('/settings', '/settings') }

    refute Tectonic::Equipment.for_account(account_id).adjustable_dumbbells?
  end
end

# #369 asks for the inventory to be "separated into a barbell plates and a dumbbell
# pairs/plates option", and the separation is what makes either readable: without headings the
# second block of ten spin buttons is ten more of the first, and the counts mean different
# things.
describe 'the settings page' do
  include Rack::Test::Methods
  include RouteOwnership
  include DumbbellRack

  it 'draws the two racks under their own headings' do
    login

    get '/settings'

    assert_includes last_response.body, 'Barbell'
    assert_includes last_response.body, 'Dumbbell plates'
    assert_includes last_response.body, 'name="dumbbell_plates[2.5]"'
  end
end

