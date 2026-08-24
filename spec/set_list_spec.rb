# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require 'securerandom'

# What the set list renders at phone width. Seven nowrap columns did not fit one: both
# action links began past the right edge of a scroll box, reachable only by a horizontal
# drag that nothing on the screen offers. Warmup and Done now stand down below Tailwind's
# 640px `sm`, which comes to one pair of classes on four cells -- and a pair that is easy
# to half-remove, since dropping `hidden` from a `<td>` while its `<th>` keeps it shifts
# every row of the table one column out of line and raises nothing. These specs read the
# rendered markup because the markup is where that would come back.
module SetList
  # Left to right, which is what lets a column be found by name.
  COLUMNS = %w[Exercise Weight Reps Warmup Done Edit Show].freeze

  # The set list of a workout holding a single set, logged as told. The body is UTF-8
  # because the table is: an em dash stands in for a flag a set does not carry.
  def list(is_warmup: false, is_completed: false)
    account_id = login
    workout = own_workout(account_id)
    exercise = DB[:exercises].insert(name: "Back Squat #{SecureRandom.hex(4)}", account_id:)
    DB[:sets].insert(workout_id: workout, exercise_id: exercise, weight: 135, reps: 5,
                     is_warmup:, is_completed:)
    get "/workouts/#{workout}/sets"
    last_response.body.dup.force_encoding(Encoding::UTF_8)
  end

  # The space after `th` is load-bearing: `<th[^>]*>` matches `<thead>` too, and the
  # whole list comes back one column out of step.
  def header(body, column)
    body.scan(/<th\s[^>]*>/)[COLUMNS.index(column)]
  end

  def cell(body, column)
    body.scan(/<td[^>]*>/)[COLUMNS.index(column)]
  end

  # Everything the Exercise cell holds, which on a phone is the name and the markers.
  def exercise_cell(body)
    body[%r{<tbody.*?<td[^>]*>(.*?)</td>}m, 1]
  end

  # A tag's classes as a list rather than as a string, so that `hidden` cannot be
  # answered by the `overflow-hidden` on some future wrapper, and so that reordering
  # the attribute -- which changes nothing a browser does -- cannot fail a test.
  def classes(tag)
    tag[/class="([^"]*)"/, 1].to_s.split
  end

  def assert_stands_down(tag, column)
    assert_includes classes(tag), 'hidden', "#{column} should be gone below sm"
    assert_includes classes(tag), 'sm:table-cell', "#{column} should return at sm"
  end
end

describe 'the columns the set list drops at phone width' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetList

  before { @body = list }

  it 'takes Warmup and Done out of the table below sm and puts them back above it' do
    %w[Warmup Done].each do |column|
      assert_stands_down header(@body, column), "#{column} header"
      assert_stands_down cell(@body, column), "#{column} cell"
    end
  end

  # The two the whole change is for. A phone that hid one of these would be back where
  # it started with fewer columns.
  it 'keeps the exercise and both action columns at every width' do
    %w[Exercise Edit Show].each do |column|
      refute_includes classes(header(@body, column)), 'hidden', "#{column} header"
      refute_includes classes(cell(@body, column)), 'hidden', "#{column} cell"
    end
  end
end

# Hiding a column is only acceptable because nothing it said is lost. Both flags ride
# under the exercise name at phone width, and only there -- from `sm` up the columns are
# back and a second copy would be noise.
describe 'what phone width keeps of the columns it drops' do
  include Rack::Test::Methods
  include RouteOwnership
  include SetList

  it 'marks a warmup under the name of the movement' do
    cell = exercise_cell(list(is_warmup: true))

    assert_includes cell, 'warmup'
    assert_includes classes(cell[/<div[^>]*>/]), 'sm:hidden'
  end

  it 'marks a set that has been logged' do
    assert_includes exercise_cell(list(is_completed: true)), 'done'
  end

  it 'marks both on a warmup that has been logged' do
    assert_includes exercise_cell(list(is_warmup: true, is_completed: true)), 'warmup · done'
  end

  # A working set still to be lifted is the common row, and it carries no marker at all:
  # the em dash the hidden columns show for it says nothing worth a second line.
  it 'says nothing under a set that is neither' do
    refute_includes exercise_cell(list), '<div'
  end
end

