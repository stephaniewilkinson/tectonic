# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/programs'
require 'securerandom'
require 'date'

# A block of `weeks` weeks opening on start_date, with no days: these specs are about
# where the weeks fall, which is decided by the block and the week number alone.
def build_block(start_date, weeks: 4)
  account_id = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
  program = Tectonic::Program.create(account_id:, name: "B#{SecureRandom.hex(4)}", block: 0, start_date:)
  (1..weeks).each { |number| Tectonic::ProgramWeek.create(program_id: program.id, number:) }
  program
end

describe 'ProgramWeek dates' do
  it 'opens each week seven days after the last, counting from the block start' do
    program = build_block(Date.new(2026, 8, 16))
    assert_equal Date.new(2026, 8, 16), program.week(1).start_date
    assert_equal Date.new(2026, 8, 30), program.week(3).start_date
  end

  it 'lands a weekday on the first matching day inside a mid-week start' do
    program = build_block(Date.new(2026, 8, 19)) # a Wednesday
    assert_equal Date.new(2026, 8, 24), program.week(1).date_for(1) # the Monday inside week 1
    assert_equal Date.new(2026, 8, 19), program.week(1).date_for(3) # the start date itself
    assert_equal Date.new(2026, 8, 31), program.week(2).date_for(1)
  end

  it 'carries a week across a year boundary without losing the seven-day spacing' do
    program = build_block(Date.new(2026, 12, 28))
    assert_equal Date.new(2027, 1, 4), program.week(2).date_for(1)
    assert_equal Date.new(2027, 1, 18), program.week(4).start_date
  end
end

describe 'a block and its weeks' do
  it 'names the week a date falls in, and nothing outside the block' do
    program = build_block(Date.new(2026, 8, 19))
    assert_equal 1, program.week_on(Date.new(2026, 8, 25)).number
    assert_equal 2, program.week_on(Date.new(2026, 8, 26)).number
    assert_nil program.week_on(Date.new(2026, 8, 18))
    assert_nil program.week_on(Date.new(2026, 9, 16))
  end

  it 'counts its weeks and marks a deload ahead of time' do
    program = build_block(Date.new(2026, 8, 17))
    program.week(4).update(is_deload: true)
    assert_equal 4, program.weeks
    assert_equal [false, false, false, true], program.program_weeks.map(&:is_deload)
  end
end

