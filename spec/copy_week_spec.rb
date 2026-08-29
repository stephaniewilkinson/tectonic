# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_editor'
require 'securerandom'

# Copying a week has to copy the whole lift. #289.
#
# `copied` listed its columns by hand, and 009's four -- measure, is_weighted, is_per_side,
# duration_seconds -- never reached the list. A column missing from a create is defaulted
# rather than refused, so the copy dropped all four: a timed lift raised
# program_lifts_measures_one_way outright, and an unweighted or per-side one came out
# quietly wrong.
#
# What is asserted here is the property rather than the four names. Asserting the names
# would be the same list again, in a second place, going stale the same way; asserting that
# a copy equals its original catches whatever is added next.
module CopyWeek
  # One lift of every shape the schema allows, because the bug was shape-specific and a
  # spec written against a plain barbell lift would have passed throughout.
  SHAPES = {
    'a plain barbell lift' => { sets: 3, reps: 5, top_weight: 225, progression: 'linear',
                                is_barbell: true, is_main: true },
    'a timed hold' => { sets: 3, reps: nil, duration_seconds: 60, measure: 'time',
                        is_weighted: false, is_barbell: false, top_weight: nil, progression: nil },
    'unweighted work' => { sets: 3, reps: 10, is_weighted: false, is_barbell: false,
                           top_weight: nil, progression: nil },
    'a lift counted per side' => { sets: 3, reps: 8, top_weight: 40, progression: 'linear',
                                   is_per_side: true, is_barbell: false },
    'a lift priced as a percentage' => { sets: 3, reps: 5, percent_of_max: 80,
                                         progression: 'percent', top_weight: nil, is_barbell: true },
    'a lift with a target effort' => { sets: 3, reps: 5, top_weight: 225, progression: 'linear',
                                       is_barbell: true, target_rpe: 8 }
  }.freeze

  def scratch_account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  # A one-week block whose single day holds one lift of the given shape.
  def block_with(account_id, attributes)
    exercise = Tectonic::Exercise.create(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}", start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1, focus: 'Squat')
    lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id,
                                        position: 0, note: 'keep the ribs down', **attributes)
    [program, lift]
  end

  def lifts_of(week)
    days = Tectonic::ProgramDay.where(program_week_id: week.id).select(:id)
    Tectonic::ProgramLift.where(program_day_id: days).order(:position).all
  end
end

describe 'copying a week' do
  include CopyWeek

  CopyWeek::SHAPES.each do |name, attributes|
    # The whole of the bug: the copy has to be the same prescription, whatever shape it is.
    # Compared on every column but the two that identify the row, so a column added to
    # program_lifts is covered by this the day it exists rather than the day somebody
    # remembers to extend the list.
    it "carries every column of #{name}" do
      account_id = scratch_account
      program, original = block_with(account_id, attributes)

      week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)
      copy = lifts_of(week_two).first

      refute_nil copy, 'the week copied no lift at all'
      assert_equal original.values.except(*Tectonic::ProgramEditor::NOT_COPIED),
                   copy.values.except(*Tectonic::ProgramEditor::NOT_COPIED)
    end
  end
end

# The two failures the old list produced, named so a regression says which one came back
# rather than only that a hash differs.
describe 'copying a week that holds a timed lift' do
  include CopyWeek

  # It raised program_lifts_measures_one_way: measure defaulted to 'reps' with no reps on
  # the row. "Add a week like the last" was a 500 on any block containing a plank.
  it 'creates the week rather than raising on the constraint' do
    account_id = scratch_account
    program, = block_with(account_id, CopyWeek::SHAPES.fetch('a timed hold'))

    week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)
    copy = lifts_of(week_two).first

    assert_equal Tectonic::Measured::TIME, copy.measure
    assert_equal 60, copy.duration_seconds
  end
end

describe 'copying a week that holds unweighted and per-side work' do
  include CopyWeek

  # The quiet one. is_weighted defaulted true, so a bodyweight lift became a weighted one
  # with no load -- and the generator prices those differently.
  it 'keeps work that carries no external load unweighted' do
    account_id = scratch_account
    program, = block_with(account_id, CopyWeek::SHAPES.fetch('unweighted work'))

    week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)

    refute lifts_of(week_two).first.is_weighted
  end

  # is_per_side defaulted false, so a split squat silently began counting half the volume it
  # should -- which is #279's bug arriving by a different route.
  it 'keeps a per-side count per side' do
    account_id = scratch_account
    program, = block_with(account_id, CopyWeek::SHAPES.fetch('a lift counted per side'))

    week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)

    assert lifts_of(week_two).first.is_per_side
  end
end

# A day of several lifts copies whole and in order, which the per-shape cases above cannot
# say: they each hold one lift, so a copy that lost the order would still pass them.
describe 'copying a week of several lifts' do
  include CopyWeek

  it 'copies all of them, in the order they were written' do
    account_id = scratch_account
    program, = block_with(account_id, CopyWeek::SHAPES.fetch('a plain barbell lift'))
    day = Tectonic::ProgramDay.where(program_week_id: program.week(1).id).first
    plank = Tectonic::Exercise.create(name: "Plank #{SecureRandom.hex(4)}", account_id:)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: plank.id, position: 1,
                                 **CopyWeek::SHAPES.fetch('a timed hold'))

    week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)

    assert_equal [0, 1], lifts_of(week_two).map(&:position)
    assert_equal [Tectonic::Measured::REPS, Tectonic::Measured::TIME], lifts_of(week_two).map(&:measure)
  end
end

