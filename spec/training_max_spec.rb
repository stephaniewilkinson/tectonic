# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require_relative '../lib/tectonic/training_max'
require_relative '../lib/tectonic/program_generator'

# A training max you can set. #264.
#
# `percent_of_max` always resolved against something -- Exercise#estimated_max reads the
# completed sets through the RPE chart -- so what this adds is not a max but a max a lifter
# can *state*, for the two cases derivation cannot reach: coming off a layoff, where the
# estimate reads work done before the break, and a movement never logged, where there is
# nothing to read at all.
#
# The rule under test everywhere here is the fallback, and it is one rule: stated, else
# derived, else nothing. Three callers ask it and none of them may answer it themselves.
#
# No `app` here, deliberately. mcp_spec defines one at the top level returning the MCP rack
# app and RouteOwnership defines one returning the web app, and the describes below want one
# each: a module method here would win over both and point every MCP call at the browser
# app, which answers a tools/call with a redirect and an empty body.
module TrainingMaxes
  def movement(account_id, name: "Lift #{SecureRandom.hex(4)}")
    Tectonic::Exercise.create(name:, account_id:, is_barbell: true)
  end

  # A completed set heavy enough for OneRepMax to read: five reps at 200 restates through
  # the RPE-8 chart to about 247.
  def lifted(account_id, exercise, weight: 200, reps: 5)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now)
    DB[:sets].insert(workout_id:, exercise_id: exercise.id, weight:, reps:,
                     is_warmup: false, is_completed: true, is_barbell: true)
  end

  def stated(account_id, exercise, pounds)
    Tectonic::TrainingMax.replace(account_id, exercise.id, pounds)
  end

  def resolve(account_id, exercise, on: Date.today)
    Tectonic::TrainingMax.for(account_id:, exercise:, on:)
  end

  def scratch_account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  end

  def library_movement
    Tectonic::Exercise.where(account_id: nil).order(:id).first
  end

  # A token and a movement of its own, which is the opening of every MCP case below. The
  # name is random rather than a real one on purpose: Resolver.exercise matches by name
  # across the account's own rows *and* the shared library, ordered by id, so asking about
  # "Safety Bar Squat" resolves the library's row rather than the one the test just made.
  def minted_movement
    minted = mint(scopes: %w[read write])
    [minted, movement(minted.account_id)]
  end

  # One block, one day, one lift priced as a percentage: the shape that resolves a max at
  # generation and the only shape that does.
  def percentage_block(account_id, exercise, percent: 65)
    program = Tectonic::Program.create(account_id:, name: 'Block', start_date: Date.today)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday, focus: 'Squat')
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets: 3, reps: 5, percent_of_max: percent, progression: 'percent',
                                 is_barbell: true, is_main: true)
    program
  end
end

describe 'which max a percentage resolves against' do
  include TrainingMaxes

  before do
    @account_id = scratch_account
    @exercise = movement(@account_id)
  end

  # The state the app was in for everybody before this, and still is for anybody who has
  # not said otherwise. The estimate is the honest default and does not go anywhere.
  it 'is the derived one when nothing has been stated' do
    lifted(@account_id, @exercise)

    assert_equal Tectonic::TrainingMax::DERIVED, resolve(@account_id, @exercise).source
  end

  # The whole feature: a stated number beats a derived one even when both exist. This is the
  # layoff case -- the sets are still there and still readable, and they are no longer what
  # the block is built on.
  it 'is the stated one when there is one, even with lifting to derive from' do
    lifted(@account_id, @exercise)
    stated(@account_id, @exercise, 315)

    assert_equal 315, resolve(@account_id, @exercise).pounds
    assert_equal Tectonic::TrainingMax::STATED, resolve(@account_id, @exercise).source
  end

  # The second case #264 names: a movement never logged has nothing to derive from, and a
  # stated max is the only thing that can make it generatable.
  it 'is the stated one on a movement that has never been lifted' do
    stated(@account_id, @exercise, 185)

    assert_equal 185, resolve(@account_id, @exercise).pounds
  end

  it 'is nothing at all with neither, which is what a percentage lift refuses over' do
    assert_nil resolve(@account_id, @exercise)
  end
end

# A derived max is a reading of history and so has a date -- asked about a block that
# finished in March it should answer what was true in March. A stated one is a standing
# instruction with no history to be as-of, so the date does not move it.
describe 'a training max asked about as of a date' do
  include TrainingMaxes

  before do
    @account_id = scratch_account
    @exercise = movement(@account_id)
  end

  it 'answers a stated one the same whatever date is asked about' do
    stated(@account_id, @exercise, 315)

    assert_equal 315, resolve(@account_id, @exercise, on: Date.today - 365).pounds
  end

  it 'answers a derived one as of the date asked about' do
    lifted(@account_id, @exercise)

    assert_nil resolve(@account_id, @exercise, on: Date.today - 365)
  end
end

# Writing one, which is mostly about what counts as *not* writing one. A max nobody can
# clear is a max stated once and kept forever, and the estimate would be unreachable after
# the first save.
describe 'stating and clearing a training max' do
  include TrainingMaxes

  before do
    @account_id = scratch_account
    @exercise = movement(@account_id)
  end

  # A blank box is how the form says "go back to estimating it".
  it 'goes back to the estimate when the stated one is cleared' do
    lifted(@account_id, @exercise)
    stated(@account_id, @exercise, 315)
    stated(@account_id, @exercise, '')

    assert_equal Tectonic::TrainingMax::DERIVED, resolve(@account_id, @exercise).source
  end

  # Zero is not a max, and one saved by accident would generate an entire block at nothing.
  # It clears rather than storing, which is the answer the constraint would give anyway but
  # with the caller left holding a working page rather than a database error.
  it 'treats zero and nonsense as clearing rather than as a number' do
    stated(@account_id, @exercise, 0)

    assert_nil resolve(@account_id, @exercise)

    stated(@account_id, @exercise, 'heavy')

    assert_nil resolve(@account_id, @exercise)
  end

  # Correcting a max is answering the same question again. Without the upsert the unique
  # index would refuse the second save, and without the index a second row would make the
  # answer depend on what Postgres felt like returning first.
  it 'replaces a stated max rather than accumulating rows' do
    stated(@account_id, @exercise, 315)
    stated(@account_id, @exercise, 325)

    assert_equal 1, DB[:account_training_maxes].where(account_id: @account_id).count
    assert_equal 325, resolve(@account_id, @exercise).pounds
  end
end

# The reason #264 is a table keyed on the pair rather than a column on exercises. A library
# movement has a null account_id and sits on every account's page, so a column there would
# be one account's number generated against by everybody -- which is precisely what
# Exercise.owned_by exists to refuse.
describe 'a training max on a shared library movement' do
  include TrainingMaxes

  it 'belongs to the account that set it and not to the movement' do
    mine = scratch_account
    stranger = scratch_account
    stated(mine, library_movement, 315)

    assert_equal 315, resolve(mine, library_movement).pounds
    assert_nil resolve(stranger, library_movement)
  end

  # Two accounts answering the same question differently about the same row, which is the
  # thing a column could not express at all.
  it 'lets two accounts carry different maxes on the same row' do
    mine = scratch_account
    theirs = scratch_account
    stated(mine, library_movement, 315)
    stated(theirs, library_movement, 225)

    assert_equal 315, resolve(mine, library_movement).pounds
    assert_equal 225, resolve(theirs, library_movement).pounds
  end
end

# The one cascade in this schema, and worth a test because it is the exception. A training
# max is a preference about a movement rather than training done on one, so a movement that
# is gone leaves a preference about nothing -- and `rake exercises:merge` really does delete
# rows, so without the cascade the merge would fail on a foreign key.
describe 'a training max whose movement is deleted' do
  include TrainingMaxes

  it 'goes with it rather than outliving it or blocking the delete' do
    account_id = scratch_account
    exercise = movement(account_id)
    stated(account_id, exercise, 315)

    exercise.delete

    assert_equal 0, DB[:account_training_maxes].where(account_id:).count
  end
end

# The caller the feature exists for. A percentage lift used to resolve against the estimate
# and nothing else, so a block written coming off a layoff generated against work done
# before it.
describe 'generating a percentage lift' do
  include TrainingMaxes

  before do
    @account_id = scratch_account
    @exercise = movement(@account_id)
    @program = percentage_block(@account_id, @exercise)
  end

  def top_working_weight
    workouts = Tectonic::ProgramGenerator.new(@program).generate(1)
    Tectonic::WorkoutSet.where(workout_id: workouts.first.id, is_warmup: false).map(&:weight).max
  end

  # 65% of a stated 400 is 260, which this rack loads exactly.
  it 'takes the percentage of a stated max' do
    stated(@account_id, @exercise, 400)

    assert_equal 260, top_working_weight
  end

  # The same rule one level up: the generator must not reach past TrainingMax for the
  # estimate of its own accord.
  it 'prefers the stated max to the derived one' do
    lifted(@account_id, @exercise)
    stated(@account_id, @exercise, 400)

    assert_equal 260, top_working_weight
  end

  # With neither it still refuses, and that stays right: inventing a max would write a whole
  # block off a guess. What changed is that the message now names both ways out, since
  # logging a set is a strange thing to require of somebody who knows what they lift.
  it 'still refuses when there is neither, and names both remedies' do
    error = assert_raises(ArgumentError) { top_working_weight }

    assert_match(/no training max/i, error.message)
    assert_match(/set one on the movement/i, error.message)
    assert_match(/log a completed set/i, error.message)
  end
end

# The browser path. A form on the movement's own page, and it is deliberately not behind the
# owner-only gate the Edit button sits behind -- the movement most people want a max on is a
# shared one.
describe 'the training max form' do
  include Rack::Test::Methods
  include RouteOwnership
  include TrainingMaxes

  before do
    @account_id = login
    @exercise = movement(@account_id)
  end

  def save(pounds)
    path = "/exercises/#{@exercise.id}/training-max"
    post path, { 'pounds' => pounds.to_s, '_csrf' => token_for_form("/exercises/#{@exercise.id}/", path) }
  end

  it 'stores what was typed' do
    save(315)

    assert_equal 315, resolve(@account_id, @exercise).pounds
  end

  it 'clears it when the box is left empty' do
    stated(@account_id, @exercise, 315)
    save('')

    assert_nil resolve(@account_id, @exercise)
  end

  it 'is offered on a shared library movement, which is the case it is most wanted for' do
    get "/exercises/#{library_movement.id}/"

    assert_includes last_response.body, "/exercises/#{library_movement.id}/training-max"
  end
end

# Three states, and the page has to say which one it is showing. A derived max presented as
# a stated one tells somebody they set a number they never set.
describe 'what the movement page says about the max it is showing' do
  include Rack::Test::Methods
  include RouteOwnership
  include TrainingMaxes

  before do
    @account_id = login
    @exercise = movement(@account_id)
  end

  it 'names the estimate as an estimate' do
    lifted(@account_id, @exercise)
    get "/exercises/#{@exercise.id}/"

    assert_includes last_response.body, 'estimated from your completed sets'
  end

  it 'names a stated max as one you set' do
    stated(@account_id, @exercise, 315)
    get "/exercises/#{@exercise.id}/"

    assert_includes last_response.body, 'which you set'
  end

  it 'says plainly when there is neither, since that is when generation refuses' do
    get "/exercises/#{@exercise.id}/"

    assert_includes last_response.body, 'cannot be generated yet'
  end
end

# The assistant's way in. A tool of its own rather than a field on update_exercise, which is
# scoped to what the account owns and refuses a library row by name.
describe 'set_training_max' do
  include Rack::Test::Methods
  include TrainingMaxes

  it 'states a max and reports what percentages now resolve against' do
    minted, exercise = minted_movement

    call_tool('set_training_max', raw: minted.raw, arguments: { exercise: exercise.name, pounds: 315 })

    assert_equal 315, resolve(minted.account_id, exercise).pounds
    assert_equal 'stated', tool_result.fetch('structuredContent').fetch('source')
  end

  # Clearing over MCP is the same call without a number, and the answer says what the
  # movement fell back to -- an assistant told only "cleared" cannot tell whether a
  # percentage lift will still generate.
  it 'clears the max when no pounds are sent, and says what it fell back to' do
    minted, exercise = minted_movement
    stated(minted.account_id, exercise, 315)

    call_tool('set_training_max', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_nil resolve(minted.account_id, exercise)
    assert_match(/cannot be generated yet/, tool_result.fetch('content').first.fetch('text'))
  end

  it 'works on a shared library movement, which update_exercise refuses' do
    minted = mint(scopes: %w[read write])

    call_tool('set_training_max', raw: minted.raw, arguments: { exercise: library_movement.name, pounds: 405 })

    assert_equal 405, resolve(minted.account_id, library_movement).pounds
  end

  it 'refuses a weight outside the bounds every other load is checked against' do
    minted, exercise = minted_movement

    call_tool('set_training_max', raw: minted.raw, arguments: { exercise: exercise.name, pounds: 9999 })

    assert tool_result.fetch('isError')
  end
end

# The read side. estimated_1rm keeps its meaning -- what the chart reads out of the sets --
# and the resolved max sits beside it, so the two disagree exactly when somebody has
# overridden the estimate and an assistant can tell that they have.
describe 'exercise_history and the two kinds of max' do
  include Rack::Test::Methods
  include TrainingMaxes

  it 'reports the derived one as both when nothing is stated' do
    minted, exercise = minted_movement
    lifted(minted.account_id, exercise)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })
    payload = tool_result.fetch('structuredContent')

    assert_equal payload.fetch('estimated_1rm'), payload.fetch('training_max')
    assert_equal 'derived', payload.fetch('training_max_source')
  end

  # The disagreement is the signal. The estimate is still reported, because it is still true
  # about the sets; the training max is what the next block will be built on.
  it 'reports them apart once a max is stated over the top of lifting' do
    minted, exercise = minted_movement
    lifted(minted.account_id, exercise)
    stated(minted.account_id, exercise, 315)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })
    payload = tool_result.fetch('structuredContent')

    assert_equal 315, payload.fetch('training_max')
    refute_equal 315, payload.fetch('estimated_1rm')
  end

  # Many clients render only the text, so the sentence has to carry which kind it is: a "max
  # 315" that turns out to be a guess off a set from before a layoff is the misreading #264
  # is about.
  it 'says in the prose which kind of max it is naming' do
    minted, exercise = minted_movement
    stated(minted.account_id, exercise, 315)

    call_tool('exercise_history', raw: minted.raw, arguments: { exercise: exercise.name })

    assert_match(/training max 315 \(the max you set\)/, tool_result.fetch('content').first.fetch('text'))
  end
end

