# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_spec' # reuses its token minting and call_tool; idempotent require
require_relative '../lib/tectonic/mcp'
require 'securerandom'
require 'date'

# Moving a session that was filed under the wrong day. #319.
#
# `create_workout` is idempotent *on* a date, so calling it with the corrected day opened a
# second session rather than moving the first, and twelve completed sets filed a day early
# could only be fixed by re-entering all of them. The browser has been able to do this all
# along, which is what made the gap sharp: an assistant was the only caller that could not
# fix a mistake an assistant is the most likely to make.
module MovingASession
  def a_trained_session(account_id, date:, name: nil)
    exercise_id = DB[:exercises].insert(name: "Lift #{SecureRandom.hex(4)}", account_id:)
    workout_id = DB[:workouts].insert(account_id:, date:, name:)
    2.times do
      DB[:sets].insert(workout_id:, exercise_id:, weight: 225, reps: 5, is_warmup: false,
                       is_barbell: true, is_completed: true, completed_at: Time.now)
    end
    workout_id
  end

  def date_of(workout_id) = DB[:workouts].where(id: workout_id).get(:date).to_date

  def yesterday = Date.today - 1
end

describe 'moving a session onto the day it was trained' do
  include Rack::Test::Methods
  include MovingASession

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id = a_trained_session(@minted.account_id, date: yesterday)
    call_tool('update_workout', raw: @minted.raw,
                                arguments: { workout_id: @workout_id, date: Date.today.to_s })
  end

  it 'changes the date' do
    assert_equal Date.today, date_of(@workout_id)
  end

  # The sets are the reason this exists: re-entering twelve of them was the only remedy,
  # so a move that took them off the session would be no remedy at all.
  it 'takes the training with it' do
    assert_equal 2, DB[:sets].where(workout_id: @workout_id).count
  end

  it 'says what moved, the way every other edit tool does' do
    assert_includes tool_result.dig('content', 0, 'text'), 'date'
    assert tool_result.dig('structuredContent', 'changed', 'date')
  end
end

# Send only what changes, which is update_set's rule. A name and a note go through the same
# cleaner the browser uses, so the two write paths agree about what saying nothing looks like.
describe 'correcting what a session is called' do
  include Rack::Test::Methods
  include MovingASession

  before do
    @minted = mint(scopes: %w[read write])
    @workout_id = a_trained_session(@minted.account_id, date: Date.today, name: 'Morning')
  end

  def field(name) = DB[:workouts].where(id: @workout_id).get(name)

  it 'sets a name and a note without touching the date' do
    call_tool('update_workout', raw: @minted.raw,
                                arguments: { workout_id: @workout_id, name: 'Evening',
                                             note: 'slept badly' })

    assert_equal 'Evening', field(:name)
    assert_equal 'slept badly', field(:note)
    assert_equal Date.today, date_of(@workout_id)
  end

  # '' clears and absent leaves alone, which is create_workout's rule and the reason a note
  # can be removed at all.
  it 'clears a name sent empty and leaves an unsent one alone' do
    call_tool('update_workout', raw: @minted.raw, arguments: { workout_id: @workout_id, name: '' })

    assert_nil field(:name)
  end

  it 'reports nothing to change when nothing does' do
    call_tool('update_workout', raw: @minted.raw,
                                arguments: { workout_id: @workout_id, name: 'Morning' })

    assert_includes tool_result.dig('content', 0, 'text'), 'nothing to change'
  end
end

# Two sessions on a date is a feature, not a collision: #89 asked for it, workouts.name exists
# to tell them apart, and the index on (account_id, date) is non-unique on purpose. So the move
# goes through -- what gets reported is the day.
describe 'moving a session onto a day that already has one' do
  include Rack::Test::Methods
  include MovingASession

  before do
    @minted = mint(scopes: %w[read write])
    @sitting = a_trained_session(@minted.account_id, date: Date.today, name: 'Morning')
    @moving = a_trained_session(@minted.account_id, date: yesterday, name: 'Evening')
    call_tool('update_workout', raw: @minted.raw,
                                arguments: { workout_id: @moving, date: Date.today.to_s })
  end

  it 'goes through rather than refusing' do
    assert_equal Date.today, date_of(@moving)
  end

  it 'leaves the session that was already there alone' do
    assert_equal Date.today, date_of(@sitting)
    assert_equal 2, DB[:sets].where(workout_id: @sitting).count
  end

  # The thing worth surfacing is not the two rows. Resolver.workout and find_workout both
  # take order(:id).first, so after this move every date-keyed call quietly resolves to the
  # older session -- and nothing said so at the moment it became true.
  it 'names both sessions and which one a call by date will find' do
    text = tool_result.dig('content', 0, 'text')

    assert_includes text, '2 sessions'
    assert_includes text, 'Morning'
    assert_includes text, "resolves to #{@sitting}"
  end
end

# The flag marks the row order(:id).first picks and not the row that just moved, which is the
# whole point of reporting it: the moved session is usually the newer of the two, so the one a
# date-keyed call finds is the other one.
describe 'the day a moved session landed on, in the payload' do
  include Rack::Test::Methods
  include MovingASession

  it 'lists both, oldest first, marking the one that resolves' do
    minted = mint(scopes: %w[read write])
    sitting = a_trained_session(minted.account_id, date: Date.today, name: 'Morning')
    moving = a_trained_session(minted.account_id, date: yesterday, name: 'Evening')

    call_tool('update_workout', raw: minted.raw, arguments: { workout_id: moving, date: Date.today.to_s })
    day = tool_result.dig('structuredContent', 'day_holds')

    assert_equal([sitting, moving], day.map { |other| other['id'] })
    assert_equal([true, false], day.map { |other| other['resolves'] })
  end
end

# Nearly every call is one session on a day, and a tool that appended "1 session on that date"
# to all of them would train a reader to skip the line that matters on the one call where it does.
describe 'moving a session onto an empty day' do
  include Rack::Test::Methods
  include MovingASession

  it 'says nothing about the day' do
    minted = mint(scopes: %w[read write])
    workout_id = a_trained_session(minted.account_id, date: yesterday)

    call_tool('update_workout', raw: minted.raw,
                                arguments: { workout_id:, date: Date.today.to_s })

    refute_includes tool_result.dig('content', 0, 'text'), 'resolves to'
  end
end

describe 'naming a session that is not yours' do
  include Rack::Test::Methods
  include MovingASession

  it 'refuses another account s workout rather than moving it' do
    minted = mint(scopes: %w[read write])
    stranger = mint(scopes: %w[read write])
    workout_id = a_trained_session(stranger.account_id, date: yesterday)

    call_tool('update_workout', raw: minted.raw,
                                arguments: { workout_id:, date: Date.today.to_s })

    assert tool_result['isError']
    assert_includes tool_result.dig('content', 0, 'text'), 'No workout with id'
    assert_equal yesterday, date_of(workout_id)
  end

  # Parsed through the same Resolver every other tool uses, so an unparseable date is
  # refused in one voice rather than in a second one written here.
  it 'refuses a date it cannot read' do
    minted = mint(scopes: %w[read write])
    workout_id = a_trained_session(minted.account_id, date: yesterday)

    call_tool('update_workout', raw: minted.raw,
                                arguments: { workout_id:, date: 'last thursday' })

    assert tool_result['isError']
    assert_equal yesterday, date_of(workout_id)
  end
end

# The write scope, on the same terms as every other tool that changes a row.
describe 'a read-only token' do
  include Rack::Test::Methods
  include MovingASession

  it 'cannot move a session' do
    minted = mint(scopes: ['read'])
    workout_id = a_trained_session(minted.account_id, date: yesterday)

    call_tool('update_workout', raw: minted.raw,
                                arguments: { workout_id:, date: Date.today.to_s })

    assert tool_result['isError']
    assert_equal yesterday, date_of(workout_id)
  end
end

