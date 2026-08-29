# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# #259 reported that sessions rewritten after a program edit came out on weights no plate
# set can build, on the evidence that program_editor.rb never mentions rounding.
#
# It does not, and it does not need to: it delegates to ProgramGenerator#refresh, which
# writes sets through exactly the code generation does. Every weight either path writes
# has always gone through Equipment#loading. What was unrounded was the *prescription* --
# a block could ask for 152 on a rack whose smallest jump is 5, generate 135/140/145/150,
# and go on displaying 152 as the plan. Since #262 prints the load, that disagreement is
# now in front of the reader rather than only in the column.
#
# So this file pins both halves: the sets, which were right and had nothing holding them,
# and the prescription, which was not.
module Loadable
  def rack(account_id)
    Tectonic::Equipment.for_account(account_id)
  end

  def working_weights(workout)
    Tectonic::WorkoutSet.where(workout_id: workout.id).exclude(is_warmup: true).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }
  end

  def all_weights(workout)
    Tectonic::WorkoutSet.where(workout_id: workout.id).order(:id)
                        .map { |set| Tectonic::Plates.numeric(set.weight) }.compact
  end

  # A one-day block asking for a weight the default rack cannot build. 152 needs 53.5 a
  # side and the lightest pair is 2.5, so it is the audit's own number and unloadable.
  def unloadable_block(raw, top_weight: 152)
    call_tool('create_program', raw:, arguments: {
                name: "Block #{SecureRandom.hex(4)}", block: 0, start_date: Date.today.strftime('%Y-%m-%d'),
                weeks: [{ number: 1, days: [{ weekday: Date.today.wday, focus: 'Squat',
                                              lifts: [{ exercise: 'Back Squat', sets: 4, reps: 5,
                                                        top_weight:, is_main: true }] }] }]
              })
    tool_result['structuredContent']
  end

  def generate(raw, program)
    call_tool('generate_program_week', raw:, arguments: { program_id: program['id'], week: 1 })
    Tectonic::Workout.where(program_day_id: program['weeks'].first['days'].first['id']).first
  end

  # A rack whose bar steps in twos, which is what a pair of 1 lb plates buys. It is also
  # what would otherwise start prescribing 26 and 28 lb dumbbells.
  FINE = Tectonic::Equipment.new(bar_weight: 45, pairs: { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2, 1 => 2 })
end

describe 'a block asking for a weight the rack cannot build' do
  include Rack::Test::Methods
  include Loadable

  before do
    @token = mint(scopes: %w[read write])
    @program = unloadable_block(@token.raw)
  end

  # The half that was not holding. 152 was stored and read back as the plan while no
  # session would ever contain it.
  it 'stores the prescription on a weight the rack can build' do
    lift = @program['weeks'].first['days'].first['lifts'].first

    assert_equal 150, lift['top_weight']
    assert rack(@token.account_id).per_side(lift['top_weight']), 'the prescription is not loadable'
  end

  # The half the issue was about, which was already true. Asserted so it stays true.
  it 'generates every set, warmups included, on a weight the rack can build' do
    workout = generate(@token.raw, @program)
    loads = all_weights(workout)

    refute_empty loads
    loads.each { |load| assert rack(@token.account_id).per_side(load), "#{load} cannot be loaded" }
  end

  it 'tops the session out at the weight the plan says' do
    workout = generate(@token.raw, @program)

    assert_equal 150, working_weights(workout).max
  end
end

describe 'a lift edited after its week was generated' do
  include Rack::Test::Methods
  include Loadable

  before do
    @token = mint(scopes: %w[read write])
    @program = unloadable_block(@token.raw, top_weight: 150)
    @workout = generate(@token.raw, @program)
    @lift = @program['weeks'].first['days'].first['lifts'].first
  end

  # The rewrite path, which the issue named. It goes through the generator, so it rounds.
  it 'rewrites every set onto a weight the rack can build' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift['id'], top_weight: 156 })
    loads = all_weights(@workout)

    refute_empty loads
    loads.each { |load| assert rack(@token.account_id).per_side(load), "#{load} cannot be loaded" }
  end

  it 'rounds the edited prescription too, so the plan and the session agree' do
    call_tool('update_program_lift', raw: @token.raw,
                                     arguments: { program_lift_id: @lift['id'], top_weight: 156 })

    assert_equal 155, tool_result['structuredContent']['top_weight']
    assert_equal 155, working_weights(@workout).max
  end
end

describe 'what an edit that rounds tells the caller' do
  include Rack::Test::Methods
  include Loadable

  # An assistant that sent 156 and reads back "top_weight 150 to 155" can see the rack
  # answered. Rounding silently and reporting the number that was asked for would be
  # worse than not rounding at all.
  it 'reports the weight it stored rather than the one it was sent' do
    token = mint(scopes: %w[read write])
    program = unloadable_block(token.raw, top_weight: 150)
    lift = program['weeks'].first['days'].first['lifts'].first
    call_tool('update_program_lift', raw: token.raw, arguments: { program_lift_id: lift['id'], top_weight: 156 })

    assert_includes tool_result.dig('content', 0, 'text'), 'top_weight 150 to 155'
  end
end

# The dumbbell half, which #259 called separate and real. A dumbbell does not load off
# the barbell's plates, so it has no business rounding to the barbell's increment: a rack
# that gains a pair of 1 lb plates takes that increment to 2, and 26 lb dumbbells are not
# a thing most gyms have.
describe 'a weight that is not on the bar' do
  it 'steps in fives even on a rack whose bar steps in twos' do
    assert_equal 2, Loadable::FINE.increment
    assert_equal 5, Loadable::FINE.increment_for(is_barbell: false)
    assert_equal 25, Loadable::FINE.loadable(27, is_barbell: false)
  end

  it 'leaves the bar alone, which still answers from the plates themselves' do
    assert_equal 152, Loadable::FINE.loadable(152, is_barbell: true)
  end

  # The default rack already steps in fives, so the rule changes nothing for an account
  # that has never said what it owns -- which is the case worth not breaking.
  it 'changes nothing for a rack that already steps in fives' do
    plain = Tectonic::Equipment.default

    assert_equal 5, plain.increment_for(is_barbell: false)
    assert_equal 25, plain.loadable(27, is_barbell: false)
  end
end

