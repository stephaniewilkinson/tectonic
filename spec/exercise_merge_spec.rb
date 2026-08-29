# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'
require 'date'

# #267: a bare "Squat" predating the exercise library, sitting alongside Back Squat,
# High-Bar Squat and Low-Bar Squat.
#
# Untidy in a list and genuinely ambiguous over MCP, which is where it matters:
# Resolver.exercise matches on the trimmed name and creates a private row when nothing
# matches, so "squat" resolves to a coin toss between a legacy row and whichever variation
# was meant -- and a history question answered off the wrong one is answered wrongly and
# without complaint.
#
# `rake exercises:merge` is the fix, and this specs the move rather than the task
# invocation: what has to be right is that no set is lost, no prescription is left
# pointing at a row that no longer exists, and nothing belonging to a movement that
# merely looks similar is dragged along.
module Merge
  # The task's body, reached directly. Loading the Rakefile to call it would pull in the
  # migration and OAuth tasks and a second connection with them.
  def fold(from, into)
    DB.transaction do
      Tectonic::WorkoutSet.where(exercise_id: from.id).update(exercise_id: into.id)
      Tectonic::ProgramLift.where(exercise_id: from.id).update(exercise_id: into.id)
      from.delete
    end
  end

  def account
    @account ||= DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x')
  end

  # A library row is one with no account behind it, and the teardown in spec_helper spares
  # those on purpose -- they are what `rake library:exercises` leaves in a deployed
  # database, not test data. Which means a spec that makes one has to take it away again,
  # or it outlives the run and every count of the library is one too many afterwards.
  # test_isolation_spec exists to catch exactly that, and caught this.
  def movement(name, library: false)
    row = Tectonic::Exercise.create(name:, account_id: (library ? nil : account), is_barbell: true)
    (@library_rows ||= []) << row.id if library
    row
  end

  # Children before parents, which is the same rule spec_helper's teardown follows and for
  # the same reason: sets.exercise_id is NOT NULL with no cascade, so a movement cannot go
  # while a set points at it. This runs in an `after` block, which minitest calls *before*
  # that teardown, so the sets are still there and have to be taken first.
  def clear_library_rows
    return unless @library_rows&.any?

    Tectonic::WorkoutSet.where(exercise_id: @library_rows).delete
    Tectonic::ProgramLift.where(exercise_id: @library_rows).delete
    Tectonic::Exercise.where(id: @library_rows).delete
  end

  def logged(exercise, weight: 225)
    workout = Tectonic::Workout.create(account_id: account, date: Date.today)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight:,
                                reps: 5, is_warmup: false, is_completed: true)
  end

  def prescribed(exercise)
    program = Tectonic::Program.create(account_id: account, name: "Block #{SecureRandom.hex(4)}",
                                       start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 4, reps: 5, top_weight: 155, progression: 'fixed')
  end
end

describe 'folding a legacy movement into the one it meant' do
  include Merge

  before do
    @legacy = movement("Squat #{SecureRandom.hex(4)}")
    @real = movement("Back Squat #{SecureRandom.hex(4)}")
    @set = logged(@legacy)
    @lift = prescribed(@legacy)
  end

  it 'moves the training rather than deleting it' do
    fold(@legacy, @real)

    assert_equal @real.id, @set.refresh.exercise_id
    assert_equal 225, Tectonic::Plates.numeric(@set.refresh.weight)
  end

  # sets is not the only table pointing at exercises; program_lifts does too, and it is
  # NOT NULL with no cascade. A merge that moved only the sets would fail on the delete,
  # or -- worse, if the constraint were ever relaxed -- leave a block prescribing a
  # movement that no longer exists.
  it 'moves the prescriptions with them' do
    fold(@legacy, @real)

    assert_equal @real.id, @lift.refresh.exercise_id
  end

  it 'leaves nothing behind' do
    fold(@legacy, @real)

    assert_nil Tectonic::Exercise[@legacy.id]
    refute_nil Tectonic::Exercise[@real.id]
  end

  # The estimated max is what a percentage-priced block resolves against, so a merge that
  # lost history would quietly reprice every future week off it.
  it 'carries the history into the movement that absorbs it' do
    fold(@legacy, @real)

    refute_nil @real.estimated_max(account_id: account)
  end
end

# The row #267 is actually about has a null account_id, which makes it a library row and
# so visible on every account's page rather than one person's mistake. It is not in
# Exercise::LIBRARY, so `rake library:exercises` did not create it and will not put it
# back -- which is what makes deleting it safe rather than a thing that returns.
describe 'folding a stray library row' do
  include Merge

  after { clear_library_rows }

  it 'removes it from every account, not just the one that used it' do
    stray = movement("Squat #{SecureRandom.hex(4)}", library: true)
    real = movement("Back Squat #{SecureRandom.hex(4)}", library: true)
    logged(stray)

    assert_predicate stray, :library?
    fold(stray, real)

    assert_nil Tectonic::Exercise[stray.id]
    refute_includes Tectonic::Exercise.visible_to(account).map(&:id), stray.id
  end
end

describe 'a movement that merely looks similar' do
  include Merge

  # The reason the task matches on the exact name and refuses anything but one hit:
  # "Squat" is a prefix of four rows in this library, and telling those four apart is the
  # whole point of the exercise. A merge that swept up a prefix match would move a year of
  # low-bar work onto the back squat and call it tidying.
  it 'is left alone' do
    legacy = movement("Squat #{SecureRandom.hex(4)}")
    real = movement("Back Squat #{SecureRandom.hex(4)}")
    bystander = movement("Low-Bar Squat #{SecureRandom.hex(4)}")
    theirs = logged(bystander)
    fold(legacy, real)

    assert_equal bystander.id, theirs.refresh.exercise_id
    refute_nil Tectonic::Exercise[bystander.id]
  end
end

