# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its helpers (mint, call_tool, tool_result); idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# A session written the way the generator writes one -- planned weight and reps beside
# what is there to be lifted -- so the read tools can be checked on the fields that only
# exist because a program put them there.
def planned_session(account_id, date, exercise, lifted: nil)
  workout = Tectonic::Workout.create(account_id:, date:)
  Tectonic::WorkoutSet.insert(workout_id: workout.id, exercise_id: exercise.id, weight: lifted || 155, reps: 5,
                              planned_weight: 155, planned_reps: 5, rpe: (8 if lifted), is_warmup: false,
                              is_completed: !lifted.nil?)
  Tectonic::WorkoutSet.insert(workout_id: workout.id, exercise_id: exercise.id, weight: 45, reps: 5,
                              planned_weight: 45, planned_reps: 5, is_warmup: true, is_completed: false)
  workout
end

def account_lift(account_id, name = 'Back Squat')
  Tectonic::Exercise.create(account_id:, name: "#{name} #{SecureRandom.hex(4)}", is_barbell: true)
end

describe 'get_workout' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @exercise = account_lift(@token.account_id)
    @workout = planned_session(@token.account_id, Date.new(2027, 2, 1), @exercise, lifted: 185)
  end

  it 'returns the sets in order with what was prescribed beside what was lifted' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })
    detail = tool_result['structuredContent']
    working = detail['sets'].first
    refute detail.key?('rpe'), 'the session rating went with #209; the per-set one below is what is left'
    assert_equal 'performed', detail['status']
    assert_equal [185, 155], [working['weight'], working['planned_weight']]
    assert_equal [true, false], [working['is_completed'], working['is_warmup']]
    assert_equal 8, working['rpe']
  end
end

# The sets have always been in structuredContent. Many clients render only the text, and
# a tool whose own description promises the sets and then prints a count reads as broken.
describe 'get_workout in the text a client renders' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @exercise = account_lift(@token.account_id)
    @workout = planned_session(@token.account_id, Date.new(2027, 2, 1), @exercise, lifted: 185)
  end

  def text
    tool_result['content'].first['text']
  end

  it 'writes a line per set rather than a count' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_equal 3, text.lines.length
    assert_includes text, "#{@exercise.name} 185x5"
    assert_includes text, "#{@exercise.name} 45x5"
  end

  # 185 was lifted where 155 was written, and that gap is the whole reason both are kept.
  it 'shows the prescription where it disagrees with what was lifted' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    assert_includes text, '(planned 155x5)'
  end
end

# A ramp counted as working sets inflates every volume figure read off this, so the text
# has to carry the flags the prose used to throw away.
describe 'get_workout on the flags a prose summary drops' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @workout = planned_session(@token.account_id, Date.new(2027, 2, 1), account_lift(@token.account_id), lifted: 185)
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })
  end

  it 'marks the warmup, the completion and the set rating' do
    text = tool_result['content'].first['text']

    assert_includes text, 'warmup'
    assert_includes text, 'not done'
    assert_includes text, 'RPE 8'
    refute_includes text, 'session RPE'
  end
end

# On a session lifted exactly as written the prescription is the same numbers twice.
describe 'get_workout on a session lifted as written' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @workout = planned_session(@token.account_id, Date.new(2027, 3, 1), account_lift(@token.account_id))
  end

  # Matched on the bracket rather than the word, because an untrained session is itself
  # described as "planned" in the opening line.
  it 'stays quiet about the prescription' do
    call_tool('get_workout', raw: @token.raw, arguments: { workout_id: @workout.id })

    refute_includes tool_result['content'].first['text'], '(planned'
  end
end

describe 'get_workout by date' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @workout = planned_session(@token.account_id, Date.new(2027, 2, 1), account_lift(@token.account_id))
  end

  it 'finds the session by date as well as by id' do
    call_tool('get_workout', raw: @token.raw, arguments: { date: '2027-02-01' })
    assert_equal @workout.id, tool_result['structuredContent']['id']
  end

  it 'says nothing was trained rather than opening an empty session' do
    call_tool('get_workout', raw: @token.raw, arguments: { date: '2027-02-02' })
    assert tool_result['isError']
    assert_equal 1, Tectonic::Workout.where(account_id: @token.account_id).count
  end
end

describe 'get_workout isolation' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    @workout = planned_session(@token.account_id, Date.new(2027, 2, 1), account_lift(@token.account_id))
  end

  it "never reads another account's session" do
    call_tool('get_workout', raw: mint(scopes: ['read']).raw, arguments: { workout_id: @workout.id })
    assert tool_result['isError']
  end
end

describe 'fetch on a workout handle' do
  include Rack::Test::Methods

  it 'carries the sets as data, not only as a sentence' do
    token = mint(scopes: ['read'])
    workout = planned_session(token.account_id, Date.new(2027, 2, 3), account_lift(token.account_id), lifted: 165)
    call_tool('fetch', raw: token.raw, arguments: { id: "workout:#{workout.id}" })
    metadata = tool_result['structuredContent']['metadata']
    assert_equal 2, metadata['sets'].length
    assert_equal 155, metadata['sets'].first['planned_weight']
    assert(metadata['sets'].any? { |set| set['is_warmup'] })
  end
end

describe 'exercise_history' do
  include Rack::Test::Methods

  # Training history is the past, so these sit behind today: an estimated max is read
  # from what has been lifted by a date, and a session in 2027 has not happened yet.
  before do
    @token = mint(scopes: ['read'])
    @exercise = account_lift(@token.account_id)
    @old = Date.today - 30
    @recent = Date.today - 3
    planned_session(@token.account_id, @old, @exercise, lifted: 155)
    planned_session(@token.account_id, @recent, @exercise, lifted: 185)
  end

  it 'returns the completed sets of one movement with the max they support' do
    call_tool('exercise_history', raw: @token.raw, arguments: { exercise: @exercise.name })
    history = tool_result['structuredContent']
    assert_equal 2, history['sets'].length # the warmups were never completed
    assert_equal([@recent, @old].map { |date| date.strftime('%Y-%m-%d') },
                 history['sets'].map { |set| set['date'] })
    assert_equal 228, history['estimated_1rm'] # 185 for five at an 8
  end

  it 'narrows to a date range' do
    call_tool('exercise_history', raw: @token.raw,
                                  arguments: { exercise: @exercise.name, from: (@recent - 1).strftime('%Y-%m-%d') })
    assert_equal([@recent.strftime('%Y-%m-%d')], tool_result['structuredContent']['sets'].map { |set| set['date'] })
  end
end

# What the window does to the numbers, as distinct from which sets fall inside it.
describe 'exercise_history over a window' do
  include Rack::Test::Methods

  # Training history is the past, so these sit behind today: an estimated max is read
  # from what has been lifted by a date, and a session in 2027 has not happened yet.
  before do
    @token = mint(scopes: ['read'])
    @exercise = account_lift(@token.account_id)
    @old = Date.today - 30
    @recent = Date.today - 3
    planned_session(@token.account_id, @old, @exercise, lifted: 155)
    planned_session(@token.account_id, @recent, @exercise, lifted: 185)
  end

  it 'reads the max as of the end of the window, not as of today' do
    call_tool('exercise_history', raw: @token.raw,
                                  arguments: { exercise: @exercise.name, to: (@old + 1).strftime('%Y-%m-%d') })
    assert_equal 191, tool_result['structuredContent']['estimated_1rm'] # only the 155 had happened by then
  end

  it 'includes written but unlifted sets only when asked' do
    call_tool('exercise_history', raw: @token.raw,
                                  arguments: { exercise: @exercise.name, include_planned: true })
    assert_equal 4, tool_result['structuredContent']['sets'].length
  end
end

describe 'exercise_history isolation' do
  include Rack::Test::Methods
end

# The same history read from the other side: one session in full rather than a
# movement across sessions.
describe 'exercise_history, session by session' do
  include Rack::Test::Methods

  # Training history is the past, so these sit behind today: an estimated max is read
  # from what has been lifted by a date, and a session in 2027 has not happened yet.
  before do
    @token = mint(scopes: ['read'])
    @exercise = account_lift(@token.account_id)
    @old = Date.today - 30
    @recent = Date.today - 3
    planned_session(@token.account_id, @old, @exercise, lifted: 155)
    planned_session(@token.account_id, @recent, @exercise, lifted: 185)
  end

  # The movement is deliberately a library row -- a null account_id is what makes one
  # shared -- so it has to be taken away again. The count of library exercises is an
  # invariant spec/exercises_spec.rb asserts, and a shared row left behind by this spec
  # fails it there rather than here, which is a long way from the cause.
  it "never reaches another account's lifting of a shared movement" do
    library = Tectonic::Exercise.create(name: "Shared #{SecureRandom.hex(4)}", is_barbell: true)
    mine = mint(scopes: ['read'])
    stranger = mint(scopes: ['read'])
    planned_session(stranger.account_id, Date.today - 1, library, lifted: 405)
    call_tool('exercise_history', raw: mine.raw, arguments: { exercise: library.name })
    assert_empty tool_result['structuredContent']['sets']
    assert_nil tool_result['structuredContent']['estimated_1rm']
  ensure
    if library
      DB[:sets].where(exercise_id: library.id).delete
      DB[:exercises].where(id: library.id).delete
    end
  end
end

describe 'list_workouts bounding' do
  include Rack::Test::Methods

  before do
    @token = mint(scopes: ['read'])
    exercise = account_lift(@token.account_id)
    (1..5).each { |day| planned_session(@token.account_id, Date.new(2027, 5, day), exercise, lifted: 100 + day) }
  end

  it 'holds rows back at the limit and says how many it held' do
    call_tool('list_workouts', raw: @token.raw, arguments: { limit: 2 })
    payload = tool_result['structuredContent']
    assert_equal [2, 5, 3], payload.values_at('shown', 'total', 'withheld')
    assert_includes tool_result.dig('content', 0, 'text'), 'Showing 2 of 5'
    assert_equal(%w[2027-05-05 2027-05-04], payload['workouts'].map { |w| w['date'] })
  end

  it 'narrows to a date range and reports no withholding inside it' do
    call_tool('list_workouts', raw: @token.raw, arguments: { from: '2027-05-04', to: '2027-05-05' })
    payload = tool_result['structuredContent']
    assert_equal [2, 2, 0], payload.values_at('shown', 'total', 'withheld')
  end

  it 'says where each session stands without loading its sets' do
    call_tool('list_workouts', raw: @token.raw, arguments: { limit: 1 })
    assert_equal 'performed', tool_result['structuredContent']['workouts'].first['status']
  end
end

