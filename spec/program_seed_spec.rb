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

# Seeding used to resolve a movement with account_id and name together, which a library
# row can never match because its account_id is null on purpose. So every seeded block
# built its own private "Back Squat" beside the library one, and sets logged against the
# two never aggregated.
describe 'ProgramSeed against the shared library' do
  before { Tectonic::Exercise.load_library }

  it 'points its lifts at the library movement instead of a copy of it' do
    account_id = seed_account
    library = Tectonic::Exercise.where(account_id: nil, name: 'Back Squat').first
    Tectonic::ProgramSeed.seed(account_id)

    assert_equal 0, Tectonic::Exercise.where(account_id:, name: 'Back Squat').count
    assert_includes seeded_exercise_ids(account_id), library.id
  end

  it 'still creates a movement the library has never heard of' do
    account_id = seed_account
    Tectonic::ProgramSeed.seed(account_id)
    own = Tectonic::Exercise.where(account_id:, name: 'Glute Press Machine').all

    assert_equal 1, own.length
    assert_includes seeded_exercise_ids(account_id), own.first.id
  end

  # Every movement the block names resolves to exactly one row, whoever owns it.
  it 'leaves no movement of the block named by two rows at once' do
    account_id = seed_account
    Tectonic::ProgramSeed.seed(account_id)
    names = Tectonic::Exercise.visible_to(account_id).where(id: seeded_exercise_ids(account_id)).map(:name)

    assert_equal names.length, names.uniq.length
    assert_equal 5, names.length
  end
end

def seeded_exercise_ids(account_id)
  program = Tectonic::Program.where(account_id:).first
  days = Tectonic::ProgramDay.where(program_week_id: program.program_weeks.map(&:id)).select(:id)
  Tectonic::ProgramLift.where(program_day_id: days).map(:exercise_id).uniq
end

