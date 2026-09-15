# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/exercise_names'
require_relative '../lib/tectonic/exercises'
require 'securerandom'

# The database holds the rule, not just the two call sites that remember it. #476.
#
# #474 put folding in `Resolver::exercise` and in the browser form. That is two places today
# and it was one fewer before the browser form existed -- and `is_barbell` is this codebase's
# own record of what happens next: its comment says three write paths forgot the flag when
# each of them had to remember it, which is why `barbell?` lives on the model.
#
# An index is that argument enforced where it cannot be routed around, and it turns a silent
# wrong answer into a loud one: without it, a path that skips the fold creates a second row
# and everything carries on.
module OnePerAccount
  def an_account = DB[:accounts].insert(email: "#{SecureRandom.hex}@e.com", password_hash: 'x')

  def add(account_id, name)
    DB[:exercises].insert(account_id:, name:)
  end
end

describe 'two movements with the same name on one account' do
  include OnePerAccount

  before { @account_id = an_account }

  it 'is refused outright' do
    name = "Deadlift #{SecureRandom.hex(4)}"
    add(@account_id, name)

    assert_raises(Sequel::UniqueConstraintViolation) { add(@account_id, name) }
  end

  # The whole reason the index is over the folded name rather than the raw one: a raw unique
  # index would allow these side by side, and that is the duplicate this app actually made.
  it 'is refused through a difference in spelling' do
    stem = SecureRandom.hex(4)
    add(@account_id, "Bench Press #{stem}")

    assert_raises(Sequel::UniqueConstraintViolation) { add(@account_id, "benchpress#{stem}") }
  end

  it 'still allows two genuinely different movements' do
    add(@account_id, "Front Squat #{SecureRandom.hex(4)}")
    add(@account_id, "Back Squat #{SecureRandom.hex(4)}")

    assert_equal 2, DB[:exercises].where(account_id: @account_id).count
  end
end

# Scoped, both ways: per account, and not over the library, which keeps its own index because
# a library row has no account to be unique within.
describe 'who the rule applies to' do
  include OnePerAccount

  before { @account_id = an_account }

  it 'says nothing about another account having the same name' do
    name = "Zercher Squat #{SecureRandom.hex(4)}"
    add(@account_id, name)
    add(an_account, name)

    assert_equal 2, DB[:exercises].where(name:).count
  end

  # The library keeps its own index and is not covered by this one -- a library row has no
  # account to be unique within.
  it 'does not stop an account naming a movement the library already has' do
    library = Tectonic::Exercise.first(account_id: nil)

    assert add(@account_id, library.name).positive?
  end
end

# The index and the resolver have to fold identically. An index folding differently would
# refuse rows the app thinks are distinct and accept ones it thinks are the same, which is
# worse than having neither -- so this compares the two directly rather than trusting that
# two regular expressions written a day apart say the same thing.
describe 'what the database means by the same name' do
  include OnePerAccount

  # Real names off this account, plus the shapes most likely to fold differently: an
  # apostrophe, a slash, repeated spaces, and hyphens standing in for spaces.
  def spellings
    ['Bench Press', 'benchpress', 'BENCH-PRESS', 'Bench   Press', "Farmer's Walk",
     'Farmers Walk', '90/90 Breathing', 'Banded I-Y-T-W', 'Single-Arm DB Row', 'single arm db row']
  end

  it 'agrees with the fold the app resolves names by' do
    spellings.each do |spelling|
      in_ruby = Tectonic::ExerciseNames.fold(spelling)
      in_sql = DB.get(Sequel.function(:lower,
                                      Sequel.function(:regexp_replace, spelling, '[^a-zA-Z0-9]', '', 'g')))

      assert_equal in_ruby, in_sql, "#{spelling.inspect} folds differently in SQL"
    end
  end
end

