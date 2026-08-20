# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_seed'
require 'securerandom'
require 'date'

def seed_account
  DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

describe 'ProgramSeed' do
  it 'creates the program with its week, its day and every lift' do
    program = Tectonic::ProgramSeed.seed(seed_account)
    week = program.program_weeks.first
    assert_equal 1, program.weeks
    assert_equal 1, week.program_days.count
    assert_equal 5, week.program_days.first.program_lifts.count
  end

  it 'is idempotent: reseeding the same block returns the same program' do
    account_id = seed_account
    first = Tectonic::ProgramSeed.seed(account_id)
    assert_equal first.id, Tectonic::ProgramSeed.seed(account_id).id
    assert_equal 1, Tectonic::Program.where(account_id:).count
  end

  it 'opens the block on a Monday that covers the day it was seeded' do
    program = Tectonic::ProgramSeed.seed(seed_account)
    assert_equal 1, program.start_date.wday
    assert_equal 1, program.week_on(Date.today).number
  end
end

