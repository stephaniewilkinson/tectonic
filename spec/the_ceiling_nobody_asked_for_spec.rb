# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What assuming a pair of dumbbells costs a movement nobody answered for. #439.
#
# `dumbbell_count` shipped with a deliberate default: two, because every weight loadable on a
# pair is loadable on a single, so an unanswered movement comes out a little light rather than
# impossible. That is still the right way to break the tie. What it is not is free.
#
# Plates go on both ends of every handle in use, so a pair reaches half as far up the shelf as
# one does. Against the rack this spec builds -- a 4 lb handle with pairs of 10, 5 and 2.5 --
# a single loads up to 79 lb and a pair stops at 39. A movement parked at 39 is therefore not
# necessarily at the lifter's limit; it may be at the top of a range that exists only because
# a question went unanswered, which from the session screen looks exactly like a lift that has
# stopped progressing.
module CeilingNobodyAskedFor
  # The rack from the report. Written through Equipment.replace so the totals under test come
  # out of the same enumeration the generator prescribes from.
  def an_adjustable_rack(account_id)
    Tectonic::Equipment.replace(account_id, bar_weight: 45, plates: { '45' => 1 },
                                            dumbbell_handle_weight: '4',
                                            dumbbell_plates: { '10' => 2, '5' => 2, '2.5' => 3 })
  end

  # A movement with one set on it, the weight being what decides whether the ceiling is in
  # play. `dumbbell_count` nil is the case under test; is_barbell false is every movement not
  # on a bar, which is deliberately a wider set than "dumbbell".
  #
  # `owned: false` writes a library row, and those are the one thing CleanDatabase deliberately
  # keeps -- a nil account is how the seeded library is spelled, so the cleaner cannot tell a
  # spec's stray from the real thing. It is recorded here and taken out again in an after hook
  # rather than left to accumulate until test_isolation_spec notices.
  # `planned_weight` is what decides it, not `weight`: it is the generator's own handwriting,
  # set on a row this app wrote and nil on one a person typed. `prescribed: false` is the
  # hand-logged movement, which must stay silent however heavy it is.
  def a_movement(account_id, weight:, prescribed: true, **movement)
    shown(account_id, weight:, prescribed:, movement: { owned: true, is_barbell: false, **movement })
  end

  # Its own helper rather than another keyword at the call site, and the one case it serves is
  # the whole of why the note is gated on `is_barbell`: a bar is not loaded off that shelf.
  def a_barbell_movement(account_id, weight:)
    a_movement(account_id, weight:, is_barbell: true)
  end

  def shown(account_id, weight:, prescribed:, movement:)
    exercise_id = a_row(account_id, movement)
    DB[:sets].insert(workout_id: own_workout(account_id), exercise_id:, weight:, reps: 8,
                     is_barbell: movement[:is_barbell], planned_weight: (weight if prescribed),
                     planned_reps: (8 if prescribed), is_warmup: false, is_completed: true)
    get "/exercises/#{exercise_id}/"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  def a_row(account_id, movement)
    exercise_id = DB[:exercises].insert(name: "Single-Leg DB RDL #{SecureRandom.hex(4)}",
                                        account_id: (account_id if movement[:owned]),
                                        is_barbell: movement[:is_barbell],
                                        dumbbell_count: movement[:dumbbell_count])
    (@library_rows ||= []) << exercise_id unless movement[:owned]
    exercise_id
  end

  def remove_library_rows
    return unless @library_rows

    DB[:sets].where(exercise_id: @library_rows).delete
    DB[:exercises].where(id: @library_rows).delete
  end
end

describe 'a movement sitting on the ceiling of an assumption' do
  include Rack::Test::Methods
  include RouteOwnership
  include CeilingNobodyAskedFor

  before do
    @account_id = login
    an_adjustable_rack(@account_id)
  end

  it 'says what is being assumed' do
    assert_includes a_movement(@account_id, weight: 39), 'assumes'
  end

  # Both ranges, because the gap between them is the whole argument and neither number means
  # much alone: 39 reads as a limit until 79 is next to it.
  it 'shows what a pair reaches against what one reaches' do
    body = a_movement(@account_id, weight: 39)

    assert_includes body, '4 lb to 39 lb'
    assert_includes body, '4 lb to 79 lb'
  end

  it 'names the weight nothing can be prescribed above' do
    assert_includes a_movement(@account_id, weight: 39), '39 lb</strong> can be prescribed'
  end

  it 'offers the page the question is answered on' do
    assert_includes a_movement(@account_id, weight: 39), 'Say how many'
  end
end

# The silences, which are most of this. A note on every movement that is not on a bar would be
# a prompt on 29 of them for one account here, most of them cables and machines that take no
# dumbbells at all -- and it would bury the one page where the question is live.
describe 'a movement the assumption is not costing anything' do
  include Rack::Test::Methods
  include RouteOwnership
  include CeilingNobodyAskedFor

  before do
    @account_id = login
    an_adjustable_rack(@account_id)
  end

  # Below the ceiling both answers prescribe the same weights, so the question is idle. This
  # is the lat pulldown case: nothing says it is a dumbbell movement, and nothing should ask.
  it 'is quiet while the weight is still under the ceiling' do
    refute_includes a_movement(@account_id, weight: 24), 'assumes'
  end

  it 'is quiet where the movement has already said how many' do
    refute_includes a_movement(@account_id, weight: 39, dumbbell_count: 2), 'assumes'
  end

  it 'is quiet about a barbell, which is not loaded off that shelf at all' do
    refute_includes a_barbell_movement(@account_id, weight: 225), 'assumes'
  end

  # The lat pulldown, which is what this predicate was first got wrong. A machine is on the
  # wrong side of `is_barbell` like every cable, and the reporting account has one carrying 85
  # lb across twelve hand-logged sets -- no generated set, no program lift anywhere. Telling it
  # nothing above 39 lb can be prescribed is true only in the sense that nothing is prescribed
  # for it at all, which makes it noise on a page where the question cannot arise.
  it 'is quiet about a movement nothing has ever prescribed, however heavy' do
    body = a_movement(@account_id, weight: 85, prescribed: false)

    refute_includes body, 'assumes'
  end
end

# A fixed rack is the other silence, and the load-bearing one. Without a handle weight
# `dumbbell_totals` is empty, both counts fall back to the same assumed increment, and
# answering the question would move no weight at all -- so there is nothing to report.
describe 'a lifter who has not described adjustable dumbbells' do
  include Rack::Test::Methods
  include RouteOwnership
  include CeilingNobodyAskedFor

  it 'says nothing, because the answer would change no weight' do
    account_id = login

    refute_includes a_movement(account_id, weight: 39), 'assumes'
  end
end

# A library movement belongs to everybody and the edit route refuses it, so the ceiling is
# still worth reporting and the instruction is not.
describe 'a movement this account cannot edit' do
  include Rack::Test::Methods
  include RouteOwnership
  include CeilingNobodyAskedFor

  before do
    @account_id = login
    an_adjustable_rack(@account_id)
  end

  after { remove_library_rows }

  it 'reports the ceiling without telling the lifter to do the impossible' do
    body = a_movement(@account_id, weight: 39, owned: false)

    assert_includes body, 'assumes'
    refute_includes body, 'Say how many'
  end
end

