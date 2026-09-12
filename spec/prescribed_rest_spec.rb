# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'program_generator_spec' # reuses build_program / build_week; idempotent require
require_relative 'route_ownership_spec'   # and its account/login/CSRF helpers
require_relative 'target_rpe_spec'        # and TargetRpe's block_for / prescribe, the same shape
require_relative '../lib/tectonic/program_generator'
require 'securerandom'

# A block can prescribe a rest, and the session timer counts that rather than an average. #281.
#
# The timer shipped suggesting the median of this lifter's own turnarounds, which is a
# measurement and was the honest thing to offer while there was nothing else. It is not what a
# programme asks for: five singles at 90% means five minutes between them, and defaulting that
# to whatever the lifter happened to average -- including the sessions they rushed -- makes the
# timer describe the habit instead of the instruction.
#
# So rest_seconds joins program_lifts and planned_rest_seconds joins sets, as the fourth of the
# planned_ set. What is asserted here is the prescription travelling from the block to the row;
# spec/rest_timer_spec.rb asserts the timer preferring it once it is there.
module PrescribedRest
  def squat_block(rest: nil)
    program = build_program
    lift = Tectonic::ProgramLift.where(program_day_id: program.week(1).program_days.first.id).first
    lift.update(rest_seconds: rest)
    program
  end

  def generated_sets(program)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).all
  end
end

describe 'a block that prescribes a rest' do
  include PrescribedRest

  it 'writes it onto every working set it generates' do
    working = generated_sets(squat_block(rest: 300)).reject(&:is_warmup)

    refute_empty working
    assert_equal [300], working.map(&:planned_rest_seconds).uniq
  end

  # A lift prescribes its working sets; the ramp above them is computed rather than written.
  # Three minutes between heavy singles is not three minutes between the 95lb and 135lb rungs,
  # so a prescription on a ramp row would be an instruction nobody should follow. Those fall
  # back to the measured turnaround, which is what the lifter's own warmups actually took.
  it 'leaves the warmup rungs alone' do
    warmups = generated_sets(squat_block(rest: 300)).select(&:is_warmup)

    refute_empty warmups
    assert_equal [nil], warmups.map(&:planned_rest_seconds).uniq
  end

  it 'writes nothing where the block prescribes nothing' do
    assert_equal [nil], generated_sets(squat_block).map(&:planned_rest_seconds).uniq
  end
end

# The schema is the backstop, because a bad prescription is not one bad row: the generator
# copies it onto every working set of every week the block generates. 019's argument for
# bounding target_rpe in the schema, applied unchanged.
describe 'the constraints under a prescribed rest' do
  include PrescribedRest

  def lift_of(program)
    Tectonic::ProgramLift.where(program_day_id: program.week(1).program_days.first.id).first
  end

  it 'refuses a rest of no time, which would arm a timer that fires at once' do
    assert_raises(Sequel::CheckConstraintViolation) { lift_of(build_program).update(rest_seconds: 0) }
  end

  it 'refuses one longer than any real prescription' do
    assert_raises(Sequel::CheckConstraintViolation) { lift_of(build_program).update(rest_seconds: 5400) }
  end

  it 'accepts the short rests of rest-pause and drop-set work' do
    lift_of(build_program).update(rest_seconds: 15)
  end

  # The generator's rule, enforced rather than trusted.
  it 'refuses a planned rest on a warmup row' do
    program = squat_block(rest: 300)
    warmup = generated_sets(program).find(&:is_warmup)

    assert_raises(Sequel::CheckConstraintViolation) { warmup.update(planned_rest_seconds: 300) }
  end
end

# The rule that differs from 019's, and the reason the column carries no measure clause.
#
# A target RPE belongs only on a loaded lift counted in reps: RPE is reps in reserve, so a held
# position has none and unloaded work moves nothing the app can act on. None of that is true of
# rest. A plank has a rest between holds and press-ups have one, and a schema refusing to say so
# would make a real prescription unwritable.
describe 'a prescribed rest on work that can carry no RPE target' do
  it 'is allowed on a lift counted in seconds' do
    program = build_program
    day = program.week(1).program_days.first
    exercise_id = Tectonic::Exercise.insert(account_id: program.account_id, name: "Plank #{SecureRandom.hex(4)}")
    lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 1, sets: 3,
                                        measure: 'time', duration_seconds: 60, is_weighted: false,
                                        progression: nil, rest_seconds: 90)

    assert_equal 90, lift.reload.rest_seconds
  end

  # The same row proves the asymmetry: a target on it is refused where a rest is not.
  it 'is allowed where a target RPE on the same lift would be refused' do
    program = build_program
    day = program.week(1).program_days.first
    exercise_id = Tectonic::Exercise.insert(account_id: program.account_id, name: "Plank #{SecureRandom.hex(4)}")
    lift = Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id:, position: 2, sets: 3,
                                        measure: 'time', duration_seconds: 60, is_weighted: false,
                                        progression: nil, rest_seconds: 90)

    assert_raises(Sequel::CheckConstraintViolation) { lift.update(target_rpe: 8) }
  end
end

# The block editor, which is the other half of where a prescription gets written. A column the
# tools can set and the form cannot is a column half the app cannot reach.
describe 'prescribing a rest in the block editor' do
  include Rack::Test::Methods
  include RouteOwnership
  include TargetRpe

  before do
    @account_id = login
    @program, day = block_for(@account_id)
    @lift = prescribe(day, movement(@account_id))
  end

  def edit(fields)
    path = "/programs/#{@program.id}/lifts/#{@lift.id}"
    post path, fields.merge('_csrf' => token_for_form("/programs/#{@program.id}", path))
  end

  it 'writes a rest typed into the row' do
    edit('sets' => '3', 'reps' => '5', 'top_weight' => '200', 'rest_seconds' => '180')

    assert_equal 180, @lift.refresh.rest_seconds
  end

  # Emptying the box is how a lifter goes back to the measured median, so blank has to clear
  # rather than read as "unchanged" -- ProgramEditor#symbolize reads an empty box as nil.
  it 'clears it back to the measured median when the box is emptied' do
    @lift.update(rest_seconds: 180)
    edit('sets' => '3', 'reps' => '5', 'top_weight' => '200', 'rest_seconds' => '')

    assert_nil @lift.refresh.rest_seconds
  end

  it 'offers a box for it on the page' do
    get "/programs/#{@program.id}"

    assert_includes last_response.body, 'name="rest_seconds"'
  end
end

