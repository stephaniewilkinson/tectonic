# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'mcp_program_tools_spec' # write_block; idempotent require

# The audit log, 2026-09: removing five movements from a three-week block took fifteen
# delete_program_lift calls -- the same lift, once per week -- and a note or a swap made "for
# the block" was the same update_program_lift call once per week. every_week is one call.
module EveryWeek
  def a_block
    @token = mint(scopes: %w[read write])
    write_block(@token.raw, weeks: 3)
    @program = DB[:programs].where(account_id: @token.account_id).order(:id).last
  end

  # The lift of a movement on the block's one day, week by week.
  def rows_of(name)
    DB[:program_lifts].join(:program_days, id: :program_day_id).join(:program_weeks, id: :program_week_id)
                      .join(:exercises, id: Sequel[:program_lifts][:exercise_id])
                      .where(program_id: @program[:id], Sequel[:exercises][:name] => name)
                      .order(Sequel[:program_weeks][:number]).select_all(:program_lifts).all
  end

  def call(tool, **arguments) = call_tool(tool, raw: @token.raw, arguments:)
end

describe 'removing a lift from every week of a block' do
  include Rack::Test::Methods
  include EveryWeek

  before do
    a_block
    call('delete_program_lift', program_lift_id: rows_of('Back Squat').first[:id], every_week: true)
  end

  it 'takes it out of all three weeks in one call' do
    assert_empty rows_of('Back Squat')
    assert_includes tool_result.dig('content', 0, 'text'), 'in 3 weeks'
  end

  it 'leaves what else was on the day, renumbered from the top' do
    assert_equal([0, 0, 0], rows_of('Barbell Row').map { |row| row[:position] })
  end

  it "returns each week's copy, so it can be put back" do
    assert_equal 3, tool_result.dig('structuredContent', 'removed').length
  end
end

describe 'changing a lift in every week of a block' do
  include Rack::Test::Methods
  include EveryWeek

  before { a_block }

  it "makes the same change to each week's copy" do
    call('update_program_lift', program_lift_id: rows_of('Barbell Row').first[:id], note: 'chest on the bench',
                                every_week: true)

    assert_equal(['chest on the bench'] * 3, rows_of('Barbell Row').map { |row| row[:note] })
  end

  it 'still changes only the one without the flag' do
    call('update_program_lift', program_lift_id: rows_of('Barbell Row').first[:id], note: 'week one only')

    assert_equal(['week one only', nil, nil], rows_of('Barbell Row').map { |row| row[:note] })
  end

  # One transaction: a change one week's copy refuses leaves every week as it was.
  it 'changes no week when one of them refuses it' do
    DB[:program_lifts].where(id: rows_of('Barbell Row').last[:id]).update(is_weighted: false, top_weight: nil,
                                                                          progression: nil)
    call('update_program_lift', program_lift_id: rows_of('Barbell Row').first[:id], top_weight: 100, every_week: true)

    assert tool_result['isError']
    assert_equal([95, 95], rows_of('Barbell Row').first(2).map { |row| row[:top_weight].to_i })
  end
end

