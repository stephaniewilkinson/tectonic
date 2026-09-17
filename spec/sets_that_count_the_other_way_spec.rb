# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# Completed sets that count their reps the other way from the movement itself. #392.
#
# `align_sets_per_side` brings logged sets into line when a movement's answer *changes*, and
# that change is the only moment anything checks. A movement whose answer was right all along,
# carrying sets written before it was given, has nothing to trigger the repair and nothing to
# report the drift -- so it halves a number quietly and indefinitely.
#
# It was not a small number on the reporting account. The clamshell had four completed sets
# counting one leg where the movement says two, the split squat two more, and the hip thrust's
# own default contradicted its own note. 87 reps of work counted as half, found only by going
# looking for something else.
module CountingTheOtherWay
  def a_movement(account_id, per_side:)
    Tectonic::Exercise.create(account_id:, name: "Split Squat #{SecureRandom.hex(4)}",
                              is_barbell: false, default_is_per_side: per_side)
  end

  def a_set(account_id, exercise, per_side:, completed: true)
    DB[:sets].insert(workout_id: own_workout(account_id), exercise_id: exercise.id,
                     reps: 8, weight: 40, is_barbell: false, is_warmup: false,
                     is_per_side: per_side, is_completed: completed)
  end

  def page(exercise)
    get "/exercises/#{exercise.id}/"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end
end

describe 'a movement whose sets disagree with it' do
  include Rack::Test::Methods
  include RouteOwnership
  include CountingTheOtherWay

  before { @account_id = login }

  it 'counts them and says which way round it is' do
    exercise = a_movement(@account_id, per_side: true)
    2.times { a_set(@account_id, exercise, per_side: false) }

    assert_includes page(exercise), '2 completed sets count'
  end

  # The consequence rather than the flag, because "is_per_side is false" means nothing to
  # somebody looking at a volume chart that is wrong.
  it 'names what it does to the volume' do
    exercise = a_movement(@account_id, per_side: true)
    a_set(@account_id, exercise, per_side: false)

    assert_includes page(exercise), 'half the work'
  end

  # Both directions, since a movement wrongly marked per side over-counts by exactly as much
  # as one wrongly marked bilateral under-counts.
  it 'reads the other way round for a movement counted both sides together' do
    exercise = a_movement(@account_id, per_side: false)
    a_set(@account_id, exercise, per_side: true)

    assert_includes page(exercise), 'twice the work'
  end
end

# The silences, which are what keep this from being a permanent banner.
describe 'a movement whose sets agree with it' do
  include Rack::Test::Methods
  include RouteOwnership
  include CountingTheOtherWay

  before { @account_id = login }

  it 'says nothing where every set follows the movement' do
    exercise = a_movement(@account_id, per_side: true)
    2.times { a_set(@account_id, exercise, per_side: true) }

    refute_includes page(exercise), 'completed sets count'
  end

  # The case that decides the predicate. Volume counts completed sets and nothing else, so a
  # written-and-never-lifted set disagreeing is a disagreement about a plan and cannot be
  # miscounting anything. The same movement on the reporting account carries fourteen such
  # rows, and a warning about them would be shouting about a number nothing reads.
  it 'ignores a set that was written and never lifted' do
    exercise = a_movement(@account_id, per_side: true)
    3.times { a_set(@account_id, exercise, per_side: false, completed: false) }

    refute_includes page(exercise), 'completed sets count'
  end

  it 'says nothing about a movement with no sets at all' do
    refute_includes page(a_movement(@account_id, per_side: true)), 'completed sets count'
  end
end

# Reported, not offered as a one-tap repair. The change-triggered version can tell a stale set
# from a deliberate one because it has the old answer to compare against; a standing one has no
# such discriminator, and somebody who really did both legs at once on a machine is entitled to
# have said so.
describe 'what the page does about it' do
  include Rack::Test::Methods
  include RouteOwnership
  include CountingTheOtherWay

  it 'offers no button that would overrule a deliberate set' do
    @account_id = login
    exercise = a_movement(@account_id, per_side: true)
    a_set(@account_id, exercise, per_side: false)

    refute_includes page(exercise), 'realign'
  end
end

