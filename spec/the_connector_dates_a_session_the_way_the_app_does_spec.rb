# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # its account/login helpers; idempotent require
require_relative 'mcp_spec' # and its mint/call_tool/tool_result; idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# #606. Every screen in this app dates a session by when it was trained; the connector dated
# it by when it was written for, and neither said which it was using.
#
# The two are the same date most of the time, which is what let this sit. On the account that
# reports it they are routinely two days apart, so `/workouts` said Wednesday and
# `list_workouts` said Friday about one session, and **"what did I do on Wednesday" got a
# different answer from the app and from the assistant connected to it**. That is worse than
# either date being wrong on its own: a lifter has two sources agreeing on everything except
# the one field that says which day they are talking about.
#
# What this fixes and what it deliberately does not is the shape worth holding still. `date`
# stays the stored column, because `date` is not only a field on the way out -- it is the key
# `get_workout(date:)` and `list_workouts(from:/to:)` match on, and a payload whose date
# cannot be handed back is a worse trap than one that is two days off. So the payload carries
# three dates with three names, the prose carries the trained one with the plan beside it
# where they differ, and nothing has to be guessed from a field called `date`.
module ConnectorDates
  PLANNED = Date.new(2026, 3, 20)  # a Friday: the day the block wrote the session for
  TRAINED = Date.new(2026, 3, 18)  # the Wednesday it was actually lifted

  # A session written for one day and trained on an earlier one, which is the only shape any
  # of this is about. The completion stamp is what `performed_on` reads, so it is the set's
  # `completed_at` that decides the date rather than anything on the workout.
  def a_session_trained_early(account_id, planned: PLANNED, trained: TRAINED)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: planned)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 225,
                                reps: 5, is_warmup: false, is_completed: true,
                                completed_at: Time.new(trained.year, trained.month, trained.day, 18, 0, 0))
    [workout, exercise]
  end

  # A session nobody has touched, for the half of this that is about the fallback.
  def an_untrained_session(account_id, planned: PLANNED)
    exercise = Tectonic::Exercise.create(account_id:, name: "Bench #{SecureRandom.hex(4)}", is_barbell: true)
    workout = Tectonic::Workout.create(account_id:, date: planned)
    Tectonic::WorkoutSet.create(workout_id: workout.id, exercise_id: exercise.id, weight: 135,
                                reps: 5, is_warmup: false, is_completed: false)
    [workout, exercise]
  end

  def prose = tool_result.dig('content', 0, 'text')

  def payload = tool_result['structuredContent']

  def listed = payload['workouts'].first
end

describe 'the date a tool reports a session under' do
  include Rack::Test::Methods
  include ConnectorDates

  before do
    @token = mint(scopes: %w[read])
    @workout, = a_session_trained_early(@token.account_id)
  end

  # The one the issue is named after. Three fields, and each answers a different question.
  it 'reports the day it was trained, the day it was written for, and the stamp behind them' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_equal '2026-03-18', payload['performed_or_planned_on']
    assert_equal '2026-03-20', payload['date']
    assert_equal '2026-03-18', payload['performed_on']
  end

  # The same three on a list row, because a list is where the mismatch was read.
  it 'reports the same three on every row of a list' do
    call_tool('list_workouts', raw: @token.raw)

    assert_equal '2026-03-18', listed['performed_or_planned_on']
    assert_equal '2026-03-20', listed['date']
    assert_equal '2026-03-18', listed['performed_on']
  end

  # What the app says about the same session, which is the whole point of the issue: these
  # two numbers came from different code paths and have to agree.
  it 'agrees with the date the app prints on the same session' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_equal Tectonic::Workout[@workout.id].performed_or_planned_on.strftime('%Y-%m-%d'),
                 payload['performed_or_planned_on']
  end
end

# A movement's history dates each of its rows by the session the set came from, so the same
# rule has to reach one level further down than a list of sessions does. It is the tool an
# assistant reaches for most, and its own description promises "the dates they were lifted".
describe 'the date a movement history reports a set under' do
  include Rack::Test::Methods
  include ConnectorDates

  it 'reports the day the set was lifted, and the day its session was written for' do
    token = mint(scopes: %w[read])
    _, exercise = a_session_trained_early(token.account_id, planned: Date.new(2026, 4, 3),
                                                            trained: Date.new(2026, 4, 1))
    call_tool('exercise_history', raw: token.raw, arguments: { exercise: exercise.name })
    row = payload['sets'].first

    assert_equal '2026-04-01', row['performed_or_planned_on']
    assert_equal '2026-04-03', row['date']
  end
end

describe 'what a tool prints about a session that moved' do
  include Rack::Test::Methods
  include ConnectorDates

  before do
    @token = mint(scopes: %w[read])
    @workout, = a_session_trained_early(@token.account_id)
  end

  # Plenty of clients render only the text, which is why every tool here prints its numbers
  # in a sentence as well as in the payload. The sentence was the plan date alone.
  it 'heads a session with the day it was trained' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_includes prose, '2026-03-18'
  end

  # Both, because the trained date on its own would leave a text-only reader unable to see
  # that the session had moved at all -- and unable to guess what a date argument would match.
  it 'names the day it was written for beside it' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_includes prose, '(planned for 2026-03-20)'
  end

  it 'says the same thing in a list row' do
    call_tool('list_workouts', raw: @token.raw)

    assert_includes prose, '2026-03-18 (planned for 2026-03-20)'
  end

  # A session lifted on the day it was written for is nineteen in twenty, and printing the
  # same date twice on all of them would be noise bought with nothing.
  it 'says nothing about a plan on a session trained the day it was written for' do
    workout, = a_session_trained_early(@token.account_id, planned: Date.new(2026, 5, 4),
                                                          trained: Date.new(2026, 5, 4))
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: workout.id })

    assert_includes prose, '2026-05-04'
    refute_includes prose, 'planned for'
  end
end

describe 'the date a session that has not happened reports' do
  include Rack::Test::Methods
  include ConnectorDates

  before do
    @token = mint(scopes: %w[read])
    @workout, = an_untrained_session(@token.account_id)
  end

  # The fallback, which is the half of this rule a careless reader breaks. A planned session
  # has no trained date and its planned date is the only thing it has to say for itself, so
  # `performed_or_planned_on` answers with it rather than with nothing.
  it 'falls back to the day it is written for' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_equal '2026-03-20', payload['performed_or_planned_on']
    assert_equal '2026-03-20', payload['date']
  end

  # And says so, rather than letting a reader infer "not trained" from two dates being equal
  # -- which is also true of every session trained exactly as written.
  it 'says outright that nothing has been lifted in it' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_nil payload['performed_on']
  end
end

describe 'the date argument a tool takes' do
  include Rack::Test::Methods
  include ConnectorDates

  before do
    @token = mint(scopes: %w[read])
    @workout, = a_session_trained_early(@token.account_id)
  end

  # Why `date` was not simply redefined to mean the trained day. An assistant reads a date out
  # of a payload and hands it back, and the field that round-trips has to be the one the
  # lookup uses. Redefining `date` would have made every such round trip miss by two days on
  # exactly the sessions this issue is about.
  it 'finds the session by the date the payload calls date' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })
    call_tool('get_workout', raw: @token.raw, arguments: { date: payload['date'] })

    assert_equal @workout.id, payload['id']
  end

  # Stated as the other half of the same rule, so that a change making the trained date
  # searchable has to come here and say so.
  it 'does not find it by the date it was trained on' do
    call_tool('get_workout', raw: @token.raw, arguments: { date: '2026-03-18' })

    assert_includes prose, 'No workout on 2026-03-18'
  end
end

