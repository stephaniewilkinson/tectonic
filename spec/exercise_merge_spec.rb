# frozen_string_literal: true

require_relative 'spec_helper'
require 'securerandom'
require 'date'
# Not loaded by app.rb: folding movements is a maintenance task, not something a request
# does, so the web process has no reason to carry it.
require_relative '../lib/tectonic/exercise_merge'

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
#
# #367 added the rest of that sentence. "No set is lost" was true and far too narrow: three
# of the six tables pointing at exercises are ON DELETE CASCADE, so the delete that ends a
# merge was quietly taking the stated training max, the goal and the whole statement log
# with it -- and the fourth, percent_of_exercise_id, has no cascade and failed the delete
# outright. The describes below cover one table each, because that is the granularity the
# bug had: five of the six were fine and the list was still wrong.
module Merge
  # The real move, not a copy of it. This spec used to reimplement the task's body here --
  # loading the Rakefile to call it would pull in the migration and OAuth tasks and a second
  # connection with them -- and that is exactly how #367 survived being specced: the Rakefile
  # grew stale against the schema, and the spec's private copy went stale in the same way and
  # so agreed with it. The body lives in lib now and both callers reach it.
  def fold(from, into)
    Tectonic::ExerciseMerge.fold(from, into)
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

  # A lift prescribing one movement at a percentage of another (#295). `reference` is the
  # movement being folded -- the one the percentage is taken *of* -- so the lift itself sits
  # on some third movement, or the fold would move it through exercise_id and prove nothing.
  def priced_off(reference)
    lift = prescribed(movement("Accessory #{SecureRandom.hex(4)}"))
    lift.update(percent_of_exercise_id: reference.id, percent_of_max: 70, top_weight: nil)
    lift
  end

  # A stated training max and the statement behind it, written the way TrainingMax.store
  # writes them, with the timestamp exposed so a collision has something to be resolved by.
  def stated_max(exercise, pounds: 315, at: Time.now)
    DB[:account_training_maxes].insert(account_id: account, exercise_id: exercise.id, pounds:,
                                       stated_at: at)
    DB[:account_training_max_statements].insert(account_id: account, exercise_id: exercise.id,
                                                pounds:, stated_at: at)
  end

  def goal_of(exercise, pounds: 405, at: Time.now)
    DB[:account_goals].insert(account_id: account, exercise_id: exercise.id, pounds:, set_at: at)
  end

  def maxes_on(exercise) = DB[:account_training_maxes].where(exercise_id: exercise.id).all

  def statements_on(exercise) = DB[:account_training_max_statements].where(exercise_id: exercise.id).count
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

# The four tables #367 is about.
#
# Three of them cascade on delete, so the failure they had was not an error -- it was the
# merge reporting success over a row it had just destroyed. That is why each of these
# asserts the value survived on the movement that absorbed it, rather than only that the
# merge did not raise.
describe 'carrying a stated training max' do
  include Merge

  before do
    @legacy = movement("Squat #{SecureRandom.hex(4)}")
    @real = movement("Back Squat #{SecureRandom.hex(4)}")
    stated_max(@legacy, pounds: 315)
  end

  # account_training_maxes is ON DELETE CASCADE (020), so this row went with the movement.
  # It is the number ProgramGenerator prices every percentage lift off, so losing it does not
  # announce itself -- the next generated week is simply built off the derived estimate
  # instead, about ten percent adrift, with nothing saying why.
  it 'moves the max rather than letting the delete take it' do
    fold(@legacy, @real)

    assert_equal 1, maxes_on(@real).length
    assert_equal 315, Tectonic::Plates.numeric(maxes_on(@real).first[:pounds])
  end

  # The log #308 added so "what did the block I ran in March open at" stays answerable. It
  # cascades too, and it is the one loss that could not be repaired by restating the number:
  # a statement log is history, not current state.
  it 'moves the statements behind it' do
    fold(@legacy, @real)

    assert_equal 1, statements_on(@real)
    assert_equal 0, statements_on(@legacy)
  end
end

describe 'carrying a goal and a lift priced off the movement' do
  include Merge

  before do
    @legacy = movement("Squat #{SecureRandom.hex(4)}")
    @real = movement("Back Squat #{SecureRandom.hex(4)}")
  end

  # account_goals cascades as well, and a goal is the thing "am I on pace" is measured
  # against -- so a merge that dropped it left the question unanswerable and said nothing.
  it 'moves the goal' do
    goal_of(@legacy, pounds: 405)
    fold(@legacy, @real)

    assert_equal 405, Tectonic::Goal.for(account_id: account, exercise_id: @real.id)&.pounds
  end

  # percent_of_exercise_id (023) is the one with no cascade, so its failure was the opposite
  # shape: the delete raised, the transaction rolled back, and the merge could not be run at
  # all while any block was priced off the movement being folded.
  it 'repoints the lift instead of failing the delete' do
    lift = priced_off(@legacy)
    fold(@legacy, @real)

    assert_nil Tectonic::Exercise[@legacy.id]
    assert_equal @real.id, lift.refresh.percent_of_exercise_id
  end
end

# Both per-account tables carry a UNIQUE on (account_id, exercise_id), so an account that has
# stated something about *both* movements cannot simply have the row moved. The rule is the
# one TrainingMax.as_of already reads the log by -- the later statement is the one in force --
# so the surviving row and the log behind it cannot end up disagreeing.
describe 'an account that has stated a max on both movements' do
  include Merge

  before do
    @legacy = movement("Squat #{SecureRandom.hex(4)}")
    @real = movement("Back Squat #{SecureRandom.hex(4)}")
  end

  it 'keeps the number stated later, whichever row it was on' do
    stated_max(@real, pounds: 300, at: Time.now - 86_400)
    stated_max(@legacy, pounds: 325, at: Time.now)
    fold(@legacy, @real)

    assert_equal 1, maxes_on(@real).length
    assert_equal 325, Tectonic::Plates.numeric(maxes_on(@real).first[:pounds])
  end

  # The same rule read the other way: a legacy row nobody has touched in a year does not
  # overwrite the number the lifter is actually training off today.
  it 'keeps the standing number when the legacy one is older' do
    stated_max(@real, pounds: 300, at: Time.now)
    stated_max(@legacy, pounds: 225, at: Time.now - 86_400)
    fold(@legacy, @real)

    assert_equal 1, maxes_on(@real).length
    assert_equal 300, Tectonic::Plates.numeric(maxes_on(@real).first[:pounds])
  end

  # Whichever way the collision resolves, the log keeps both -- it has no unique index for
  # exactly this reason, and a block generated against the superseded number still has to be
  # able to say so afterwards.
end

describe 'a collision in the log and in the goal' do
  include Merge

  before do
    @legacy = movement("Squat #{SecureRandom.hex(4)}")
    @real = movement("Back Squat #{SecureRandom.hex(4)}")
  end

  # Whichever way the collision above resolves, the log keeps both -- it has no unique index
  # for exactly this reason, and a block generated against the superseded number still has to
  # be able to say so afterwards.
  it 'keeps both statements either way' do
    stated_max(@real, pounds: 300, at: Time.now - 86_400)
    stated_max(@legacy, pounds: 325, at: Time.now)
    fold(@legacy, @real)

    assert_equal 2, statements_on(@real)
  end

  it 'resolves a goal collision on the same rule' do
    goal_of(@real, pounds: 405, at: Time.now - 86_400)
    goal_of(@legacy, pounds: 455, at: Time.now)
    fold(@legacy, @real)

    assert_equal 455, Tectonic::Goal.for(account_id: account, exercise_id: @real.id).pounds
  end
end

# The dry run's counts, which are what somebody reads before agreeing to the move. They were
# part of the bug rather than incidental to it: a preview listing only sets and prescribed
# lifts is how three cascading tables stayed out of sight for three migrations.
describe 'saying what would move' do
  include Merge

  it 'counts every table the move touches' do
    legacy = movement("Squat #{SecureRandom.hex(4)}")
    logged(legacy)
    prescribed(legacy)
    priced_off(legacy)
    stated_max(legacy)
    goal_of(legacy)

    assert_equal ['1 set(s)', '1 prescribed lift(s)', '1 lift(s) priced off it',
                  '1 stated training max(es)', '1 goal(s)', '1 training max statement(s)'],
                 Tectonic::ExerciseMerge.tally(legacy)
  end

  # A movement nothing points at reports an empty list rather than six zeroes, which is what
  # lets the task say "Nothing points at it" -- the answer that tells somebody they have
  # named the wrong row.
  it 'says nothing about a movement nothing points at' do
    assert_empty Tectonic::ExerciseMerge.tally(movement("Squat #{SecureRandom.hex(4)}"))
  end
end

