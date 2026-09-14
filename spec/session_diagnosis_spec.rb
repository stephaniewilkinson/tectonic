# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/session_diagnosis'
require 'securerandom'

# A session that ran long can say why. #409.
#
# Three causes look identical in the log -- the rests ran long, more was written than the time
# allowed, or the lifter started late -- and two of them are already distinguishable from what
# is stored. The third is not modelled and never will be: only the lifter knows what late
# means, and a wrong guess about it reads as an accusation.
#
# What this needed and did not have until #281 is a prescribed rest to compare against. With
# one, "the rests ran long" is a direct comparison rather than a threshold somebody chose.
module Diagnoses
  NOTHING_MEASURED = ->(_exercise_id) {}

  # The working time the estimator prices a five-rep set at, which is what has to come out of a
  # gap before it can be compared against a prescription. Spelled out here rather than
  # hard-coded below, so a change to the constant moves the fixtures with it rather than
  # turning every assertion in this file red.
  def work = Tectonic::SessionLength::SETUP_SECONDS + (5 * Tectonic::SessionLength::SECONDS_PER_REP)

  # A run of completed sets whose gaps are exactly `rests` plus the working time of the set
  # that ends each one -- so a rest of 180 against a prescription of 180 is on target, not over.
  def session_of(rests, prescribed: 180, base: Time.now)
    at = base
    [first_set(prescribed, at)] + rests.map do |rest|
      at += rest + work
      { exercise_id: 1, reps: 5, measure: 'reps', duration_seconds: nil, is_per_side: false,
        is_completed: true, completed_at: at, planned_rest_seconds: prescribed }
    end
  end

  def first_set(prescribed, at)
    { exercise_id: 1, reps: 5, measure: 'reps', duration_seconds: nil, is_per_side: false,
      is_completed: true, completed_at: at, planned_rest_seconds: prescribed }
  end

  def unlifted(count)
    Array.new(count) do
      { exercise_id: 1, reps: 5, measure: 'reps', duration_seconds: nil, is_per_side: false,
        is_completed: false, completed_at: nil, planned_rest_seconds: 180 }
    end
  end

  def diagnose(sets, active_seconds: nil)
    Tectonic::SessionDiagnosis.of(sets, turnaround: NOTHING_MEASURED, active_seconds:)
  end

  # The same session on the table rather than in memory, for the two readers that go through
  # a request. One rest well over its prescription by default.
  def a_long_session(account_id, rests: [180, 700], unfinished: 0)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout_id = DB[:workouts].insert(account_id:, date: Date.today)
    at = Time.now - 3600
    insert_set(workout_id, exercise, at, done: true)
    rests.each { |rest| insert_set(workout_id, exercise, at += rest + work, done: true) }
    unfinished.times { insert_set(workout_id, exercise, nil, done: false) }
    workout_id
  end

  def insert_set(workout_id, exercise, at, done:)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5, is_warmup: false,
                     is_completed: done, is_barbell: true, completed_at: at, planned_rest_seconds: 180)
  end
end

# The bug this would have had if a turnaround were compared to a prescription directly. A
# turnaround is the rest *plus* the working time of the set that ended it, so a session lifted
# exactly as written would have come back as "every rest ran over".
describe 'a session lifted exactly as prescribed' do
  include Diagnoses

  it 'reports no rest as having run over' do
    assert_equal 0, diagnose(session_of([180, 180, 180])).over_rest
  end

  it 'has nothing at all to say' do
    found = diagnose(session_of([180, 180, 180]))

    refute found.anything?
    assert_nil Tectonic::SessionDiagnosis.sentence(found)
  end
end

describe 'a session whose rests ran long' do
  include Diagnoses

  it 'counts the ones that did' do
    found = diagnose(session_of([180, 400, 420, 180]))

    assert_equal 2, found.over_rest
  end

  # Twelve out of eighteen and twelve out of a hundred are different sessions, and the bare
  # count cannot tell them apart.
  it 'says how many rests there were to be over' do
    found = diagnose(session_of([180, 400, 420, 180]))

    assert_equal 4, found.compared
    assert_includes Tectonic::SessionDiagnosis.sentence(found), '2 of 4 rests'
  end

  # A set the block said nothing about cannot have taken longer than it was told to. Counting
  # it against this lifter's own median would turn "you rested longer than usual" into "you did
  # it wrong", which is a judgement rather than a measurement.
  it 'says nothing about rests the block never prescribed' do
    found = diagnose(session_of([600, 600], prescribed: nil))

    assert_equal 0, found.over_rest
    assert_equal 0, found.compared
  end
end

describe 'the gap that explains a session' do
  include Diagnoses

  it 'is named when one is long enough to be the story' do
    found = diagnose(session_of([180, 632, 180]))

    assert_equal 632, found.longest_gap
    # "10m" rather than "10m 32s", which is what #409's example writes. The seconds are
    # Timing.phrase's decision and it is the right one -- above two minutes nobody reads them
    # -- and a second duration format in one app so that one sentence could match an issue
    # would be the drift that formatter exists to prevent.
    assert_includes Tectonic::SessionDiagnosis.sentence(found), 'one gap of 10m'
  end

  # "The longest gap was 2m 10s" on a session of two-minute rests is a sentence that says
  # nothing.
  it 'is left out when the longest rest is unremarkable' do
    assert_nil diagnose(session_of([130, 120, 125])).longest_gap
  end

  # Twenty-five minutes is somebody who walked away, and a session logged either side of
  # midnight would otherwise report a fourteen-hour rest as a rest that ran long. Timing
  # already counts those separately and the record already prints the count.
  it 'ignores a gap too long to have been training at all' do
    found = diagnose(session_of([180, 60 * 60 * 14, 180]))

    assert_equal 0, found.over_rest
    assert_nil found.longest_gap
  end
end

describe 'a session that stopped part way' do
  include Diagnoses

  it 'says how much was left' do
    found = diagnose(session_of([180, 180]) + unlifted(15))

    assert_equal 15, found.unfinished
    assert_includes Tectonic::SessionDiagnosis.sentence(found), '15 sets unfinished'
  end

  it 'counts one as one' do
    found = diagnose(session_of([180]) + unlifted(1))

    assert_includes Tectonic::SessionDiagnosis.sentence(found), '1 set unfinished'
  end
end

# The arithmetic said out loud rather than a verdict: what was written, against the time the
# session actually ran.
describe 'a session with more written than the time allowed' do
  include Diagnoses

  it 'can tell that the prescription was longer than the session' do
    found = diagnose(session_of([180, 180]) + unlifted(20), active_seconds: 600)

    assert found.overprescribed?
  end

  it 'says nothing about it without a session length to compare against' do
    refute diagnose(session_of([180, 180])).overprescribed?
  end
end

# #409 is explicit that the order matters: a session that ran long and still moved a training
# max is a good session. The three facts come in the order the issue writes them.
describe 'the sentence' do
  include Diagnoses

  it 'reads rests, then the gap, then what was left' do
    found = diagnose(session_of([180, 632, 400]) + unlifted(15))

    assert_equal '2 of 3 rests ran over the prescription, one gap of 10m, 15 sets unfinished',
                 Tectonic::SessionDiagnosis.sentence(found)
  end
end

describe 'the record page' do
  include Rack::Test::Methods
  include RouteOwnership
  include Diagnoses

  it 'says why the session ran the way it did' do
    account_id = login
    workout_id = a_long_session(account_id)

    get "/workouts/#{workout_id}"

    assert_includes last_response.body, 'rests ran over the prescription'
  end

  # Below how long it took and below when it was, which #409 is explicit about: a session that
  # ran long and still moved a training max is a good session, and the ordering has to say so.
  it 'puts it under the length rather than above it' do
    account_id = login
    workout_id = a_long_session(account_id)

    get "/workouts/#{workout_id}"

    assert_operator last_response.body.index('rests ran over'), :>,
                    last_response.body.index('between sets')
  end
end

# A session lifted exactly as written gets no line at all, rather than a line saying that
# everything was fine -- which is the difference between a diagnosis and a scolding.
describe 'the record page for a session with nothing to explain' do
  include Rack::Test::Methods
  include RouteOwnership
  include Diagnoses

  it 'says nothing' do
    account_id = login
    workout_id = a_long_session(account_id, rests: [180, 180])

    get "/workouts/#{workout_id}"

    refute_includes last_response.body, 'rests ran over'
  end
end

describe 'a session read back over the connector' do
  include Rack::Test::Methods
  include Diagnoses

  # The surface that needs this most: a session an assistant reads back is a list of sets and a
  # length, and "62m" over 15 of 30 sets has three explanations that look identical.
  it 'carries the numbers and the sentence' do
    minted = mint(scopes: %w[read write])
    workout_id = a_long_session(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })
    found = tool_result.dig('structuredContent', 'diagnosis')

    assert_equal 1, found['rests_over_prescription']
    assert_equal 2, found['rests_compared']
    assert_includes found['summary'], '1 of 2 rests'
  end
end

# Every session logged before #281 and every one not yet trained has no stamps to measure
# between.
describe 'a session with nothing measured, read back over the connector' do
  include Rack::Test::Methods
  include Diagnoses

  it 'carries no diagnosis at all' do
    minted = mint(scopes: %w[read write])
    exercise = Tectonic::Exercise.create(account_id: minted.account_id, name: "Squat #{SecureRandom.hex(4)}")
    workout_id = DB[:workouts].insert(account_id: minted.account_id, date: Date.today)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight: 155, reps: 5,
                     is_warmup: false, is_completed: false)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_nil tool_result.dig('structuredContent', 'diagnosis')
  end
end

