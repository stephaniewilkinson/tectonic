# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/program_generator'
require_relative '../lib/tectonic/program_editor'
require_relative '../lib/tectonic/progression'

# A prescription can ask for an effort, not only a load. #265.
#
# sets.rpe recorded what a set was; nothing said what it should be, so "top set at RPE 8"
# -- which is how autoregulated programming is written, and the better instruction than a
# percentage exactly when a percentage is least reliable -- could not be expressed at all.
#
# Two columns, because a target that never reaches the gym floor is a note in a file.
# program_lifts.target_rpe is what the block asks; sets.planned_rpe is that target copied
# onto the rows the generator writes, beside planned_weight and planned_reps. Having all
# three on one row is what makes "asked for" and "happened" comparable, which is the reason
# to do this rather than the display.
module TargetRpe
  def scratch_account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  def movement(account_id)
    Tectonic::Exercise.create(name: "Lift #{SecureRandom.hex(4)}", account_id:, is_barbell: true)
  end

  # A one-week block with a single day, ready for lifts to be hung off it.
  def block_for(account_id)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}", start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday, focus: 'Squat')
    [program, day]
  end

  def prescribe(day, exercise, **overrides)
    Tectonic::ProgramLift.create({ program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                   sets: 3, reps: 5, top_weight: 200, progression: 'linear',
                                   is_barbell: true, is_main: true }.merge(overrides))
  end

  def generated_sets(program)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    Tectonic::WorkoutSet.where(workout_id: workout.id).order(:id).all
  end
end

# The database is the one place the rule cannot be forgotten by a caller, which is #211's
# argument for sets_rpe_only_on_working_reps and is why this column takes one too.
describe 'where a target RPE may sit' do
  include TargetRpe

  before do
    @account_id = scratch_account
    _program, @day = block_for(@account_id)
    @exercise = movement(@account_id)
  end

  it 'is accepted on a loaded lift counted in reps' do
    assert_equal 8, prescribe(@day, @exercise, target_rpe: 8).target_rpe
  end

  # RPE is reps in reserve, so a held position has no reps for any to be spare of. The
  # scale the app prints is written entirely in rep counts.
  it 'is refused on a lift counted in seconds' do
    assert_raises(Sequel::CheckConstraintViolation) do
      prescribe(@day, @exercise, target_rpe: 8, measure: 'time', reps: nil,
                                 duration_seconds: 60, top_weight: nil, progression: nil, is_weighted: false)
    end
  end

  # #278 decided the screen does not ask for a rating on work carrying no external load, so
  # a target there would print an instruction with no buttons under it to answer.
  it 'is refused on a lift carrying no external load' do
    assert_raises(Sequel::CheckConstraintViolation) do
      prescribe(@day, @exercise, target_rpe: 8, is_weighted: false, top_weight: nil, progression: nil)
    end
  end
end

# sets.rpe is a bare Integer with no range constraint, so this database will store a rating
# of 80 today; what stops one is the MCP bounds and five buttons. A target has neither guard
# behind it -- it is typed into a box by somebody with no scale in front of them -- and a
# nonsense one is copied onto every working set of every week the block generates.
describe 'the scale a target RPE is held to' do
  include TargetRpe

  before do
    @account_id = scratch_account
    _program, @day = block_for(@account_id)
    @exercise = movement(@account_id)
  end

  it 'refuses a number off the scale entirely' do
    assert_raises(Sequel::CheckConstraintViolation) { prescribe(@day, @exercise, target_rpe: 80) }
  end

  # 1 to 10 rather than the 6 to 10 the session screen offers. Those five buttons are a
  # decision about which part of the scale is worth a thumb, not a claim that RPE 5 is not a
  # number: speed work and deload weeks are written at 5.
  it 'accepts the speed and deload end of the scale the buttons do not offer' do
    assert_equal 5, prescribe(@day, @exercise, target_rpe: 5).target_rpe
  end
end

# The target has to reach the gym floor, and a set row has no program_lift_id -- so the
# generator copies it, exactly as it has copied planned_weight and planned_reps since 001.
describe 'generating a session from a lift with a target' do
  include TargetRpe

  before do
    @account_id = scratch_account
    @program, day = block_for(@account_id)
    prescribe(day, movement(@account_id), target_rpe: 8)
    @sets = generated_sets(@program)
  end

  it 'writes the target onto every working set' do
    working = @sets.reject(&:is_warmup)

    refute_empty working
    assert(working.all? { |set| set.planned_rpe == 8 })
  end

  # A ramp rung is computed as a fraction of the top set rather than chosen for how it
  # should feel, so a target on one is an instruction nobody can follow.
  it 'writes it onto no warmup' do
    warmups = @sets.select(&:is_warmup)

    refute_empty warmups
    assert(warmups.none?(&:planned_rpe))
  end
end

describe 'generating a session from a lift with no target' do
  include TargetRpe

  it 'leaves planned_rpe empty rather than inventing one' do
    account_id = scratch_account
    program, day = block_for(account_id)
    prescribe(day, movement(account_id))

    assert(generated_sets(program).none?(&:planned_rpe))
  end
end

# Week two is week one again, a little heavier. A column added to program_lifts and not
# added to `copied` is silently dropped by the copy rather than refused, which would make
# "top set at RPE 8" hold for the first week of a block and quietly stop applying after it.
describe 'copying a week that carries a target' do
  include TargetRpe

  it 'takes the target with it' do
    account_id = scratch_account
    program, day = block_for(account_id)
    prescribe(day, movement(account_id), target_rpe: 9)
    week_two = Tectonic::ProgramEditor.new(account_id).add_week(program, copy_from: 1)
    days = Tectonic::ProgramDay.where(program_week_id: week_two.id).select(:id)

    assert_equal [9], Tectonic::ProgramLift.where(program_day_id: days).select_map(:target_rpe)
  end
end

# The session screen is where a target has to be read, one line above the buttons that
# answer it.
describe 'the session row for a set with a target' do
  include Rack::Test::Methods
  include RouteOwnership
  include TargetRpe

  before do
    @account_id = login
    program, day = block_for(@account_id)
    prescribe(day, movement(@account_id), target_rpe: 8)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    get "/workouts/#{workout.id}/session"
    @body = last_response.body
  end

  it 'says what effort was asked for' do
    assert_includes @body, 'Target'
    assert_match(%r{Target</span> RPE 8}, @body)
  end

  # Two bare numbers a centimetre apart, one prescribed and one recorded, with nothing
  # saying which is which, is the failure this label exists to prevent.
  it 'still offers the buttons that answer it' do
    assert_includes @body, 'name="rpe"'
  end
end

# The poll digest is "what the screen renders". A column the screen renders and the digest
# ignores is a change an assistant could make -- retargeting a lift and regenerating the day
# -- that the poll answers 204 to, leaving the old instruction on screen.
describe 'the session fingerprint' do
  include TargetRpe

  it 'notices a target changing' do
    account_id = scratch_account
    program, day = block_for(account_id)
    prescribe(day, movement(account_id), target_rpe: 8)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first
    before = workout.session_fingerprint
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(planned_rpe: nil).update(planned_rpe: 9)

    refute_equal before, workout.session_fingerprint
  end
end

# The block editor row. The target is written and cleared the same way a price is: an empty
# box is nil rather than zero, which is what makes clearing it the same gesture as never
# having set one.
describe 'the block editor' do
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

  it 'writes a target typed into the row' do
    edit('sets' => '3', 'reps' => '5', 'top_weight' => '200', 'target_rpe' => '8')

    assert_equal 8, @lift.refresh.target_rpe
  end

  it 'clears it when the box is emptied' do
    @lift.update(target_rpe: 8)
    edit('sets' => '3', 'reps' => '5', 'top_weight' => '200', 'target_rpe' => '')

    assert_nil @lift.refresh.target_rpe
  end

  it 'offers a box for it on the page' do
    get "/programs/#{@program.id}"

    assert_includes last_response.body, 'name="target_rpe"'
  end
end

# The reason the issue gives for doing this at all: the gap between what was asked for and
# what happened, readable back. Nothing autoregulates on it yet, and that is deliberate --
# changing how loads move is its own argument, and this is the number it would be made with.
describe 'reading the gap between target and actual' do
  it 'is positive when the set was harder than prescribed' do
    assert_equal 1, Tectonic::Progression.rpe_gap({ planned_rpe: 8, rpe: 9 })
  end

  it 'is negative when it was easier' do
    assert_equal(-2, Tectonic::Progression.rpe_gap({ planned_rpe: 8, rpe: 6 }))
  end

  it 'is zero when the prescription was answered exactly' do
    assert_equal 0, Tectonic::Progression.rpe_gap({ planned_rpe: 8, rpe: 8 })
  end

  # An unrated set is not a set taken exactly as written, and counting it as one is how an
  # average comes out reassuring.
  it 'is nothing at all when the question was not put or not answered' do
    assert_nil Tectonic::Progression.rpe_gap({ planned_rpe: 8, rpe: nil })
    assert_nil Tectonic::Progression.rpe_gap({ planned_rpe: nil, rpe: 9 })
  end
end

describe 'writing a target over MCP' do
  include Rack::Test::Methods
  include TargetRpe

  before do
    @raw = mint(scopes: %w[read write]).raw
    call_tool('create_program', raw: @raw,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1, days: [{ weekday: 1, focus: 'Squat',
                                                                           lifts: [squat_lift] }] }] })
    @program = tool_result['structuredContent']
  end

  def squat_lift
    { exercise: 'Back Squat', sets: 4, reps: 5, top_weight: 155, is_main: true, target_rpe: 8 }
  end

  it 'accepts it with the block and reads it back' do
    assert_equal 8, @program['weeks'].first['days'].first['lifts'].first['target_rpe']
  end

  it 'prints it after the load, so the load still reads first' do
    call_tool('get_program', raw: @raw, arguments: { program_id: @program['id'] })

    assert_includes tool_result.dig('content', 0, 'text'), 'Back Squat 4x5 @ 155, target RPE 8'
  end

  it 'clears it when nulled through update_program_lift' do
    lift = @program['weeks'].first['days'].first['lifts'].first
    call_tool('update_program_lift', raw: @raw, arguments: { program_lift_id: lift['id'], target_rpe: nil })

    assert_nil tool_result['structuredContent']['target_rpe']
  end
end

# Refused by name rather than left to the constraint. A constraint violation reaches a
# client as a database error and reads as the tool being broken; this says which lift and
# why, which is a sentence a model can correct from.
describe 'refusing a target where it means nothing' do
  include Rack::Test::Methods
  include TargetRpe

  it 'refuses one on a timed lift and says why' do
    raw = mint(scopes: %w[read write]).raw
    call_tool('create_program', raw:,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1, days: [{ weekday: 1, lifts: [plank] }] }] })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'reps in reserve'
  end

  def plank
    { exercise: 'Plank', sets: 3, measure: 'time', duration_seconds: 60,
      is_weighted: false, target_rpe: 8 }
  end

  it 'refuses one out of range by naming the bound' do
    raw = mint(scopes: %w[read write]).raw
    call_tool('create_program', raw:,
                                arguments: { name: "B#{SecureRandom.hex(4)}", start_date: '2027-01-04',
                                             weeks: [{ number: 1, days: [{ weekday: 1,
                                                                           lifts: [{ exercise: 'Back Squat', sets: 3,
                                                                                     reps: 5, top_weight: 155,
                                                                                     target_rpe: 44 }] }] }] })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'Target RPE 44 is out of range'
  end
end

# The read-back the issue is really asking for: both halves of the prescription on one line.
describe 'get_workout on a rated set' do
  include Rack::Test::Methods
  include TargetRpe

  before do
    @minted = mint(scopes: %w[read write])
    program, day = block_for(@minted.account_id)
    prescribe(day, movement(@minted.account_id), target_rpe: 8)
    @workout = Tectonic::ProgramGenerator.new(program).generate(1).first
  end

  def rate(rpe)
    Tectonic::WorkoutSet.where(workout_id: @workout.id).exclude(planned_rpe: nil)
                        .update(rpe:, is_completed: true)
    call_tool('get_workout', raw: @minted.raw, arguments: { workout_id: @workout.id })
    tool_result.dig('content', 0, 'text')
  end

  it 'prints the answer against the target where they differ' do
    assert_includes rate(9), 'RPE 9 (target 8)'
  end

  # On a set taken exactly as asked it is the same figure twice, which is the rule the
  # planned weight above it already follows.
  it 'prints one number where they agree' do
    text = rate(8)

    assert_includes text, 'RPE 8'
    refute_includes text, '(target 8)'
  end
end

# A target nobody has answered yet. Printing a bare number here would be read as the rating,
# which is the one reading that is certainly wrong.
describe 'get_workout on a set with a target and no rating' do
  include Rack::Test::Methods
  include TargetRpe

  it 'says the target is outstanding rather than printing a bare number' do
    minted = mint(scopes: %w[read write])
    program, day = block_for(minted.account_id)
    prescribe(day, movement(minted.account_id), target_rpe: 8)
    workout = Tectonic::ProgramGenerator.new(program).generate(1).first

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: workout.id })

    assert_includes tool_result.dig('content', 0, 'text'), 'RPE target 8, not yet rated'
  end
end

