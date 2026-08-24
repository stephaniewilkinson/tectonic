# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# How one row of the session screen reads, asserted against rendered markup because all
# of it is about what a lifter sees rather than about what is stored.
#
# Three complaints met here. The plate line was headed "per side", which is a phrase this
# app already spends on something else. It printed nothing at all for a weight the rack
# cannot make, which is the silence a lifter reads as "nothing to put on". And the button
# that completes a set was grey on a warmup and lime on a working set, so the same colour
# meant "done" in one place and "not done" in the other.
module SessionRow
  # One warmup and one working set of the same lift, so the two rows can be held against
  # each other. Both are on a bar, since the plate line is the thing under test.
  def session(weight: 155, warmup_done: false, working_done: false, **working)
    account_id = login
    workout_id = own_workout(account_id)
    exercise_id = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    common = { workout_id:, exercise_id:, reps: 5, is_barbell: true }
    DB[:sets].insert(**common, weight: 45, is_warmup: true, is_completed: warmup_done)
    DB[:sets].insert(**common, weight:, is_warmup: false, is_completed: working_done, **working)
    get "/workouts/#{workout_id}/session"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # The Done/Undo buttons in document order, as [label, classes]. The RPE buttons are
  # left out by the label: they are numbers, and they are a different question.
  def complete_buttons(body)
    body.scan(%r{<button\b[^>]*>\s*(?:Done|Undo)\s*</button>}).map do |tag|
      [tag[%r{>\s*(\w+)\s*</button>}, 1], tag[/class="([^"]*)"/, 1].to_s.split]
    end
  end

  # A class that paints rather than one that sizes. This is the list that has to agree
  # between a warmup button and a working-set button: px-4 against px-5 is a difference
  # in emphasis and is allowed, bg-gray-200 against bg-lime-500 is the bug.
  PAINT = /\A(bg-|border-[a-z]|text-(white|black|(gray|sky|lime|amber)-)|hover:)/

  def paint(classes)
    classes.grep(PAINT).sort
  end
end

describe 'the button that completes a set' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow

  # The size may differ -- a working set is the bigger thing on the screen -- but nothing
  # that carries meaning may. A warmup Done that is grey while a working Done is lime is
  # two vocabularies on one screen, and grey is also what a disabled control looks like.
  it 'paints a warmup and a working set alike when the two are in the same state' do
    [true, false].each do |done|
      warmup, working = complete_buttons(session(warmup_done: done, working_done: done))

      assert_equal warmup.first, working.first
      assert_equal paint(warmup.last), paint(working.last)
    end
  end

  it 'sizes a warmup smaller than a working set all the same' do
    warmup, working = complete_buttons(session)

    assert_includes warmup.last, 'text-sm'
    assert_includes working.last, 'text-base'
  end
end

describe 'what the button colour says' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow

  # Filled for the action on offer, outlined for the one that reverses it, and the two
  # told apart by fill rather than by hue, so neither reads as the row's state.
  it 'fills Done and outlines Undo' do
    done, = complete_buttons(session(warmup_done: false))
    undone, = complete_buttons(session(warmup_done: true))

    assert_equal 'Done', done.first
    assert_includes done.last, 'bg-sky-800'
    assert_equal 'Undo', undone.first
    assert_includes undone.last, 'bg-white'
  end

  # Lime is the completed state on this screen -- the progress bar and the row tint -- so
  # a lime button, which only ever sits on a row that is not done, meant the opposite.
  it 'leaves lime to the row tint and the progress bar' do
    complete_buttons(session(warmup_done: true)).each do |button|
      assert_empty button.last.grep(/lime/)
    end
  end

  # A green button turning grey under the thumb read as the tap having failed.
  it 'never changes hue on hover' do
    complete_buttons(session).flat_map { |button| button.last.grep(/\Ahover:bg-/) }.each do |hover|
      assert_match(/\Ahover:bg-sky-/, hover)
    end
  end
end

describe 'the plate line' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow

  it 'is headed plate math rather than per side' do
    body = session

    assert_includes body, 'Plate math'
    assert_includes body, '1×45 1×10'
  end

  # 124 on a 45 lb bar is 39.5 a side, which the default rack cannot make, and this row
  # used to print nothing whatsoever -- at the one moment the arithmetic is hardest.
  it 'names the nearest loadable weight rather than going quiet' do
    body = session(weight: 124)

    assert_includes body, 'closest 125: 1×25 1×10 1×5'
  end

  # The unloadable case is the same one line as the loadable one, not a second line that
  # every clean row would then have to make room for.
  it 'costs a row no extra line when the weight loads cleanly' do
    assert_equal 2, session(weight: 155).scan('Plate math').length
    assert_equal 2, session(weight: 124).scan('Plate math').length
  end
end

describe 'the other per side' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionRow

  # Two unrelated facts wore the same words. The plate line's "per side" meant "this is
  # what one end of the bar takes"; a set's is_per_side means the reps are counted per
  # side, as a Bulgarian split squat written 3x8 per side is, and Sets#counted_reps,
  # ProgramLift and Volume all double the work on the strength of it. Renaming the first
  # is one find-and-replace away from silently halving somebody's unilateral volume, so
  # the surviving one is pinned here rather than left to be noticed later.
  it 'still says per side of a rep count that is per side' do
    body = session(is_per_side: true)

    assert_includes body, '5 per side'
    assert_includes body, 'Plate math'
  end
end

