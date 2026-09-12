# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require 'securerandom'

# Marking a movement per side reaches the training already logged. #392.
#
# "I updated clamshell to be per-side but it didn't update my workout." A set carries its own
# is_per_side, copied from the movement when it was written, and that copy is normally right:
# a set records how it was done, the way planned_weight records what was asked for.
#
# This flag is the exception, and the reason is what it is. It is not a choice somebody made
# per set -- a split squat is done one leg at a time and always was -- so the only reason a
# logged set says otherwise is that the app did not know yet. Until the sets move, the volume
# on those sessions is out by half.
module PerSideBackfill
  def movement(account_id, per_side: false)
    Tectonic::Exercise.create(name: "Clamshell #{SecureRandom.hex(4)}", account_id:,
                              default_is_per_side: per_side)
  end

  def logged_set(account_id, exercise, per_side: false, **overrides)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert({ workout_id:, exercise_id: exercise.id, weight: 20, reps: 10,
                       is_warmup: false, is_completed: true, is_barbell: false,
                       is_per_side: per_side }.merge(overrides))
  end

  def per_side_of(set_id) = DB[:sets].where(id: set_id).get(:is_per_side)

  # The edit form posts every field, so the box being ticked is the whole of the change.
  def save_movement(exercise, per_side:)
    post '/exercises', { 'id' => exercise.id.to_s, 'name' => exercise.name,
                         'note' => '', '_csrf' => token_for_form("/exercises/#{exercise.id}/edit", '/exercises') }
      .merge(per_side ? { 'default_is_per_side' => '1' } : {})
  end
end

describe 'marking a movement per side' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  before do
    @account_id = login
    @exercise = movement(@account_id)
  end

  it 'moves the sets already logged against it' do
    set_id = logged_set(@account_id, @exercise)
    save_movement(@exercise, per_side: true)

    assert per_side_of(set_id)
  end

  it 'moves them back when the box is unticked again' do
    set_id = logged_set(@account_id, @exercise, per_side: true)
    @exercise.update(default_is_per_side: true)
    save_movement(@exercise, per_side: false)

    refute per_side_of(set_id)
  end

  # A set an assistant set explicitly against the default was a decision about that set, and
  # this is not entitled to overrule it. Only the rows that were following the movement move.
  it 'leaves a set that already differed from the movement alone' do
    deliberate = logged_set(@account_id, @exercise, per_side: true)
    following = logged_set(@account_id, @exercise)
    save_movement(@exercise, per_side: true)

    assert per_side_of(deliberate), 'a set that already said per side is unchanged'
    assert per_side_of(following)
  end
end

# A save that does not move the flag must not move any sets either. The form posts every field
# on every save, so without this a lifter fixing a typo in the name would rewrite the training.
describe 'saving a movement without changing the answer' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  it 'touches nothing' do
    account_id = login
    exercise = movement(account_id)
    set_id = logged_set(account_id, exercise, per_side: true)
    save_movement(exercise, per_side: false)

    assert per_side_of(set_id), 'the movement already said no; nothing should have moved'
  end
end

# It rewrites sets somebody has lifted and moves the volume on those sessions by half, so it
# says so. A lifter who ticks the box and sees nothing happen cannot tell the fix from the bug.
describe 'what the page says about it' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  before do
    @account_id = login
    @exercise = movement(@account_id)
  end

  # Follows the redirect once and reads the line off the page it lands on. Once, because a
  # second follow_redirect! on the page it already landed on is an error rather than a re-read.
  def notice
    follow_redirect!
    last_response.body[/role="status"[^>]*>\s*([^<]+)/, 1].to_s.strip
  end

  it 'says how many logged sets it moved, and which way' do
    2.times { logged_set(@account_id, @exercise) }
    save_movement(@exercise, per_side: true)
    said = notice

    assert_includes said, '2 logged sets'
    assert_includes said, 'per side'
  end

  it 'counts one set as one, not as a plural' do
    logged_set(@account_id, @exercise)
    save_movement(@exercise, per_side: true)

    assert_includes notice, '1 logged set of this movement'
  end
end

# Nothing moved, nothing said. A line reporting zero sets would be noise on the common case of
# marking a movement per side before ever training it.
describe 'a movement with no training behind it' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  it 'says nothing, having moved nothing' do
    account_id = login
    exercise = movement(account_id)
    save_movement(exercise, per_side: true)
    follow_redirect!

    refute_includes last_response.body, 'role="status"'
  end
end

# Read once. A reload should not re-announce an edit made ten minutes ago.
describe 'how long the notice lasts' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  it 'is gone on the next view of the page' do
    account_id = login
    exercise = movement(account_id)
    logged_set(account_id, exercise)
    save_movement(exercise, per_side: true)
    follow_redirect!
    get "/exercises/#{exercise.id}/"

    refute_includes last_response.body, 'role="status"'
  end
end

# The scope cannot matter today, because only a private movement is editable and every set of
# one is the owner's. It is here so that stays true if a library movement ever becomes
# editable -- an unscoped UPDATE on a shared row would rewrite every account's training.
describe 'whose sets it may move' do
  include Rack::Test::Methods
  include RouteOwnership
  include PerSideBackfill

  it 'never reaches another account, even for the same exercise row' do
    account_id = login
    exercise = movement(account_id)
    stranger = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
    theirs = logged_set(stranger, exercise)
    save_movement(exercise, per_side: true)

    refute per_side_of(theirs)
  end

  # A library movement is not editable at all, so the backfill has nothing to reach through.
  # The token comes off the new-exercise form rather than off an edit page, because a library
  # movement has no edit page for this account -- which is the refusal being asserted.
  #
  # Cleaned up by hand, unlike every other row here. The teardown empties the tables between
  # tests but keeps the built-in library on purpose, and a library row is exactly what this
  # makes -- so left behind it would outlive the file and be counted by the three specs that
  # assert the library's size.
  it 'refuses the edit outright on a movement the account does not own' do
    login
    library = Tectonic::Exercise.create(name: "Shared #{SecureRandom.hex(4)}", account_id: nil)
    set_id = logged_set(DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x'), library)
    post '/exercises', { 'id' => library.id.to_s, 'name' => library.name, 'note' => '',
                         'default_is_per_side' => '1',
                         '_csrf' => token_for_form('/exercises/new', '/exercises') }

    refute per_side_of(set_id)
    refute library.refresh.default_is_per_side
  ensure
    DB[:sets].where(exercise_id: library&.id).delete
    library&.delete
  end
end

