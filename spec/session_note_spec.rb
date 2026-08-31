# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'route_ownership_spec' # reuses its account/login/CSRF helpers; idempotent require
require_relative 'mcp_spec'             # and its token minting and call_tool
require 'securerandom'

# Somewhere to say why a session went the way it did. #310.
#
# program_lifts.note and exercises.note both exist and a session had nowhere to put anything.
# It matters most beside what the app has only just started recording: an RPE of 9 on a set
# prescribed at 8 (#265) and a long turnaround (#281) are both kept now and neither says why.
# "Slept badly" is the answer to both, and it is available on the day and gone by the
# following week.
module SessionNote
  def a_session(account_id, note: nil)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date: Time.now, note:)
    DB[:sets].insert(workout_id:, exercise_id:, weight: 155, reps: 5,
                     is_warmup: false, is_completed: true, is_barbell: true)
    workout_id
  end
end

describe 'writing a note on a session' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before { @account_id = login }

  def save(workout_id, fields)
    post '/workouts', fields.merge('id' => workout_id.to_s, 'date' => Date.today.strftime('%m/%d/%Y'),
                                   '_csrf' => token_for_form("/workouts/#{workout_id}/edit", '/workouts'))
  end

  it 'stores what was typed' do
    workout_id = a_session(@account_id)
    save(workout_id, 'note' => 'Bar felt slow today, slept badly')

    assert_equal 'Bar felt slow today, slept badly', DB[:workouts].where(id: workout_id).get(:note)
  end

  # Blank clears rather than storing an empty string, which is Workout.clean_text's rule --
  # '' is truthy, so a blank note kept as itself would draw its own empty paragraph under
  # every session forever.
  it 'clears it when the box is emptied' do
    workout_id = a_session(@account_id, note: 'slept badly')
    save(workout_id, 'note' => '   ')

    assert_nil DB[:workouts].where(id: workout_id).get(:note)
  end
end

# The record is where a note is read back, above the numbers rather than under them: an RPE
# of 9 and a long turnaround both read differently once "slept badly" is on the page.
describe 'a note on the record' do
  include Rack::Test::Methods
  include RouteOwnership
  include SessionNote

  before { @account_id = login }

  it 'is shown' do
    workout_id = a_session(@account_id, note: 'Bar felt slow today')
    get "/workouts/#{workout_id}/"

    assert_includes last_response.body, 'Bar felt slow today'
  end

  it 'draws nothing at all for a session with none' do
    workout_id = a_session(@account_id)
    get "/workouts/#{workout_id}/"

    refute_includes last_response.body, 'whitespace-pre-line'
  end
end

# The main consumer: an assistant reading a session back is the one that would otherwise
# reason about a bad week without knowing there was a reason for it.
describe 'reading a session note over MCP' do
  include Rack::Test::Methods
  include SessionNote

  it 'is in the prose above the sets, and in the payload' do
    minted = mint(scopes: %w[read write])
    workout_id = a_session(minted.account_id, note: 'slept badly')

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    assert_includes tool_result.dig('content', 0, 'text'), 'note: slept badly'
    assert_equal 'slept badly', tool_result.dig('structuredContent', 'note')
  end

  # Above the sets rather than after them, because an assistant reading the sets first has
  # already drawn its conclusion by the time it reaches the reason.
  it 'comes before the first set rather than after the last' do
    minted = mint(scopes: %w[read write])
    workout_id = a_session(minted.account_id, note: 'slept badly')

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })
    text = tool_result.dig('content', 0, 'text')

    assert_operator text.index('note:'), :<, text.index('155x5')
  end

  it 'contributes no line at all for a session with none' do
    minted = mint(scopes: %w[read write])
    workout_id = a_session(minted.account_id)

    call_tool('get_workout', raw: minted.raw, arguments: { workout_id: })

    refute_includes tool_result.dig('content', 0, 'text'), 'note:'
    assert_nil tool_result.dig('structuredContent', 'note')
  end
end

# create_workout carries it on the same terms as the name: absent leaves it, an empty string
# clears it. A note usually arrives after the fact, once there is something to say, and this
# tool is idempotent on the day so the second call is the one that carries it.
describe 'writing a note through create_workout' do
  include Rack::Test::Methods
  include SessionNote

  it 'sets it on a session that already exists' do
    minted = mint(scopes: %w[read write])
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today' })
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today', note: 'slept badly' })

    assert_equal 'slept badly', tool_result.dig('structuredContent', 'note')
  end

  it 'leaves an existing note alone when none is sent' do
    minted = mint(scopes: %w[read write])
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today', note: 'slept badly' })
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today', name: 'Evening' })

    assert_equal 'slept badly', tool_result.dig('structuredContent', 'note')
  end

  it 'clears it when sent empty' do
    minted = mint(scopes: %w[read write])
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today', note: 'slept badly' })
    call_tool('create_workout', raw: minted.raw, arguments: { date: 'today', note: '' })

    assert_nil tool_result.dig('structuredContent', 'note')
  end
end

