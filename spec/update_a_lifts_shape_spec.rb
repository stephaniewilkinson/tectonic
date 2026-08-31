# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'

# Changing how a lift is done, after it has been written. #305.
#
# create_program and add_program_lift have always accepted is_weighted, is_per_side, measure
# and duration_seconds. update_program_lift accepted none of the four, so a lift's shape was
# fixed at the moment it was written and the only way to change it was to delete the lift and
# add it back -- losing its position and its note.
#
# The case that made it sharp: a split squat written unweighted and later loaded with
# dumbbells was refused with "Drop the load, or set is_weighted", which named a remedy the
# tool would not take. A refusal telling a caller to do something the API cannot express is
# worse than a plain no, because a model retries it.
module LiftShape
  def a_written_lift(account_id, **overrides)
    exercise = Tectonic::Exercise.create(name: "Split Squat #{SecureRandom.hex(4)}", account_id:)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}", start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: 1)
    Tectonic::ProgramLift.create({ program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                   sets: 3, reps: 8, is_weighted: false, top_weight: nil,
                                   progression: nil, is_barbell: false,
                                   note: 'keep the ribs down' }.merge(overrides))
  end

  def revise(raw, lift, arguments)
    call_tool('update_program_lift', raw:, arguments: { program_lift_id: lift.id }.merge(arguments))
    tool_result
  end
end

describe 'loading a lift that was written unweighted' do
  include Rack::Test::Methods
  include LiftShape

  before do
    @minted = mint(scopes: %w[read write])
    @lift = a_written_lift(@minted.account_id)
  end

  it 'takes the weight once is_weighted comes with it' do
    revise(@minted.raw, @lift, { is_weighted: true, top_weight: 40 })
    @lift.refresh

    assert @lift.is_weighted
    assert_equal 40, @lift.top_weight
  end

  # The bug found while building this, and the reason the probe was worth running. The
  # progression rule was computed from the row's old is_weighted while the new one was
  # written beside it, so the row failed program_lifts_weight_matches_progression -- as a
  # check violation rather than as a refusal anybody could read.
  it 'gives it a progression rule to match, rather than a row the database refuses' do
    revise(@minted.raw, @lift, { is_weighted: true, top_weight: 40 })

    assert_equal 'linear', @lift.refresh.progression
  end

  # The whole reason to edit rather than delete and re-add.
  it 'keeps the note and the position it already had' do
    revise(@minted.raw, @lift, { is_weighted: true, top_weight: 40 })
    @lift.refresh

    assert_equal 'keep the ribs down', @lift.note
    assert_equal 0, @lift.position
  end
end

# The refusal was always right; what was wrong is that it named a field the tool would not
# take. It still fires, and now the remedy it suggests is reachable.
describe 'loading a lift without saying it is weighted' do
  include Rack::Test::Methods
  include LiftShape

  it 'is still refused, by a message whose remedy now works' do
    minted = mint(scopes: %w[read write])
    lift = a_written_lift(minted.account_id)

    result = revise(minted.raw, lift, { top_weight: 40 })

    assert result['isError']
    assert_includes result.dig('content', 0, 'text'), 'set is_weighted'
  end
end

describe 'turning a rep-counted lift into a timed one' do
  include Rack::Test::Methods
  include LiftShape

  # measure and its quantity travel together, because sets_measures_one_way refuses a row
  # carrying reps under measure 'time'. The shape is recomputed rather than passed through,
  # so the quantity always agrees with the measure.
  it 'sets the duration and empties the rep count' do
    minted = mint(scopes: %w[read write])
    lift = a_written_lift(minted.account_id)

    revise(minted.raw, lift, { measure: 'time', duration_seconds: 45 })
    lift.refresh

    assert_equal Tectonic::Measured::TIME, lift.measure
    assert_equal 45, lift.duration_seconds
    assert_nil lift.reps
  end

  it 'refuses to become timed with no duration to hold for' do
    minted = mint(scopes: %w[read write])
    lift = a_written_lift(minted.account_id)

    result = revise(minted.raw, lift, { measure: 'time' })

    assert result['isError']
    assert_includes result.dig('content', 0, 'text'), 'needs duration_seconds'
  end
end

describe 'flagging a count as per side after the fact' do
  include Rack::Test::Methods
  include LiftShape

  # The case the retest hit: a split squat counting half its volume, noticed a week in.
  it 'sets the flag and leaves the rep count alone' do
    minted = mint(scopes: %w[read write])
    lift = a_written_lift(minted.account_id)

    revise(minted.raw, lift, { is_per_side: true })
    lift.refresh

    assert lift.is_per_side
    assert_equal 8, lift.reps
  end
end

# An edit that touches none of the four has to leave the shape exactly as it was, which is
# what recomputing it only when one of them is sent buys.
describe 'an edit that does not touch the shape' do
  include Rack::Test::Methods
  include LiftShape

  it 'reports only what actually moved' do
    minted = mint(scopes: %w[read write])
    lift = a_written_lift(minted.account_id, is_weighted: true, top_weight: 40, progression: 'linear')

    changed = revise(minted.raw, lift, { sets: 4 }).dig('structuredContent', 'changed')

    assert_equal %w[sets], changed.keys
  end
end

