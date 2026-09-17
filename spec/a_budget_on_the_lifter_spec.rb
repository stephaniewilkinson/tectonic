# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and token minting and call_tool
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# How long a session should take, on the account rather than only on the block. #446.
#
# `programs.time_budget_minutes` has existed since 032 and **not one block ever carried one**.
# `create_program` accepts it, `update_program` accepts it, `generate_program_week` warns when
# a day runs past it, `SessionLength.against` does the comparison. A whole feature, built, and
# never once run -- so the deadlift day at 29 sets across four movements was never flagged, not
# because nothing checks but because there was no cap to check against.
#
# The first reading was that #411 removed the only way to set it. That is not quite right, and
# #458 is why: it asks for no *CRUD* interface and names the exception -- "one number per
# movement and one editable field, not a CRUD interface".
#
# So it is a wrong-object problem. Everything else on `programs` belongs to its block and
# changes between blocks -- preferred_reps, is_ascending, start_date. "I have an hour to train"
# is a fact about a lifter's week, the same next block and the one after.
module LifterBudget
  def a_block(account_id, budget: nil, sets: 12)
    program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}",
                                       start_date: Date.today, time_budget_minutes: budget)
    week = Tectonic::ProgramWeek.create(program_id: program.id, number: 1)
    day = Tectonic::ProgramDay.create(program_week_id: week.id, weekday: Date.today.wday)
    exercise = Tectonic::Exercise.create(account_id:, name: "Squat #{SecureRandom.hex(4)}", is_barbell: true)
    Tectonic::ProgramLift.create(program_day_id: day.id, exercise_id: exercise.id, position: 0,
                                 sets:, reps: 5, top_weight: 200, progression: 'linear',
                                 is_main: true, is_barbell: true)
    program
  end

  def budget_on(account_id, minutes)
    DB[:accounts].where(id: account_id).update(time_budget_minutes: minutes)
  end
end

describe 'whose hour a block is judged against' do
  include LifterBudget

  before { @account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x') }

  # The case the column was dormant for: a block that says nothing now inherits an answer
  # instead of switching the check off.
  it 'falls back to the lifter where the block says nothing' do
    budget_on(@account_id, 60)

    assert_equal 60, a_block(@account_id).budget_minutes
  end

  # A peaking week really can be longer than an ordinary one, and that is a fact about the
  # block rather than about the lifter.
  it 'lets the block override where it says something' do
    budget_on(@account_id, 60)

    assert_equal 90, a_block(@account_id, budget: 90).budget_minutes
  end

  # An account that has said nothing keeps exactly the behaviour it has now, which is silence.
  it 'is nothing where neither has said' do
    assert_nil a_block(@account_id).budget_minutes
  end

  it 'does not read another account budget' do
    budget_on(DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x'), 60)

    assert_nil a_block(@account_id).budget_minutes
  end
end

# The point of the fallback: the warning that has never fired now can.
describe 'generating a week against a budget nobody put on the block' do
  include Rack::Test::Methods
  include LifterBudget

  before do
    @token = mint(scopes: %w[read write])
    budget_on(@token.account_id, 20)
    @program = a_block(@token.account_id, sets: 12)
  end

  it 'names the overshoot' do
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program.id, week: 1 })

    assert_includes tool_result.dig('content', 0, 'text'), '20 minute budget'
  end

  # A reader comparing estimated_minutes against this wants the number the warning was judged
  # by, not the column it happened to come from.
  it 'reports the budget it judged by rather than the empty column' do
    call_tool('generate_program_week', raw: @token.raw, arguments: { program_id: @program.id, week: 1 })

    assert_equal 20, tool_result['structuredContent']['time_budget_minutes']
  end
end

describe 'setting it on the settings page' do
  include Rack::Test::Methods
  include RouteOwnership
  include LifterBudget

  before { @account_id = login }

  def save(minutes)
    post '/settings/budget', { 'minutes' => minutes, '_csrf' => token_for_form('/settings', '/settings/budget') }
  end

  def stored = DB[:accounts].where(id: @account_id).get(:time_budget_minutes)

  it 'offers the field' do
    get '/settings'

    assert_includes last_response.body, 'name="minutes"'
  end

  it 'records it and reads it back' do
    save('60')
    get '/settings'

    assert_equal 60, stored
    assert_match(/id="minutes"[^>]*value="60"/, last_response.body)
  end

  # Blank is how the warning is turned off, and has to stay sayable.
  it 'clears it when the box is emptied' do
    save('60')
    save('')

    assert_nil stored
  end
end

# Refused rather than clamped, on the same terms as the per-movement rest: clamping 600 to 300
# would store a number nobody typed and then judge every session against it.
describe 'a session length nobody trains for' do
  include Rack::Test::Methods
  include RouteOwnership
  include LifterBudget

  before { @account_id = login }

  def save(minutes)
    post '/settings/budget', { 'minutes' => minutes, '_csrf' => token_for_form('/settings', '/settings/budget') }
  end

  it 'refuses one too long rather than clamping it' do
    save('600')

    assert_nil DB[:accounts].where(id: @account_id).get(:time_budget_minutes)
  end

  it 'refuses one too short to be a session' do
    save('2')

    assert_nil DB[:accounts].where(id: @account_id).get(:time_budget_minutes)
  end
end

