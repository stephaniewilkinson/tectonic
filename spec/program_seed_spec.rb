# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/program_seed'
require 'securerandom'

def seed_account
  DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')
end

describe 'ProgramSeed' do
  it 'creates the program with its day and every lift' do
    program = Tectonic::ProgramSeed.seed(seed_account)
    assert_equal 1, program.program_days.count
    assert_equal 5, program.program_days.first.program_lifts.count
  end

  it 'is idempotent: reseeding the same block and week returns the same program' do
    account_id = seed_account
    first = Tectonic::ProgramSeed.seed(account_id)
    assert_equal first.id, Tectonic::ProgramSeed.seed(account_id).id
    assert_equal 1, Tectonic::Program.where(account_id:).count
  end
end

