# frozen_string_literal: true

require_relative 'spec_helper'
require_relative '../lib/tectonic/duplicate_accounts'
require 'securerandom'

Duplicates = Tectonic::DuplicateAccounts

# #345's other half. The index in migration 027 is what stops a second account being made,
# and it could not go on while duplicates were already there -- so something had to decide
# what happened to the ones the database already held.
#
# 027 first refused on any duplicate at all, reasoning that one of the two rows owns training
# somebody did. Against production that reasoning did not hold: it named eleven addresses and
# twenty-one of the twenty-two rows owned nothing anywhere in the schema. The deploy was
# stopped on empty rows for six days, and the password reset flow behind it never shipped.
#
# So the refusal is kept and narrowed to the case that earns it.
describe 'choosing between two accounts on one address' do
  # The case that stopped the deploy. Neither row is anybody's training, so neither is a
  # question about a person, and the older one survives.
  it 'keeps the oldest when neither owns anything' do
    rows = [{ id: 151, owns: false }, { id: 154, owns: false }]

    assert_equal [154], Duplicates.deletable(rows)
  end

  # The row that holds the training survives whether or not it is the older one, because
  # which row is older is an accident of which device somebody reached for first.
  it 'keeps the one that owns something, even when it is newer' do
    rows = [{ id: 3, owns: false }, { id: 22, owns: true }]

    assert_equal [3], Duplicates.deletable(rows)
  end

  it 'keeps the one that owns something when it is the older one' do
    rows = [{ id: 3, owns: true }, { id: 22, owns: false }]

    assert_equal [22], Duplicates.deletable(rows)
  end

  # The whole reason the refusal exists. Both rows hold work somebody did, so which one
  # survives is a question about a person and this is not entitled to answer it.
  it 'refuses to choose when both own something' do
    rows = [{ id: 3, owns: true }, { id: 22, owns: true }]

    assert_nil Duplicates.deletable(rows)
  end

  # Nothing in the schema limited a duplicate to a pair, so neither does this.
  it 'clears every empty row of three, not just one' do
    rows = [{ id: 5, owns: false }, { id: 9, owns: false }, { id: 12, owns: false }]

    assert_equal [9, 12], Duplicates.deletable(rows)
  end
end

describe 'the plan across every duplicated address' do
  # A refusal names every address needing a decision rather than the first one found, so
  # they are resolved in one pass instead of one per failed deploy.
  it 'reports all the unresolved addresses at once' do
    _deletions, unresolved = Duplicates.plan(
      'a@example.com' => [{ id: 1, owns: true }, { id: 2, owns: true }],
      'b@example.com' => [{ id: 3, owns: false }, { id: 4, owns: false }],
      'c@example.com' => [{ id: 5, owns: true }, { id: 6, owns: true }]
    )

    assert_equal ['a@example.com', 'c@example.com'], unresolved.sort
  end

  # One address needing a person does not hold up the ones that do not, because the
  # deletions and the refusal are computed together rather than the first raising.
  it 'still collects the deletions it is sure of' do
    deletions, = Duplicates.plan(
      'a@example.com' => [{ id: 1, owns: true }, { id: 2, owns: true }],
      'b@example.com' => [{ id: 3, owns: false }, { id: 4, owns: false }]
    )

    assert_equal [4], deletions
  end

  it 'has nothing to do with a database holding no duplicates' do
    assert_equal [[], []], Duplicates.plan({})
  end
end

describe 'the refusal' do
  it 'says nothing when every address was resolved' do
    assert_nil Duplicates.refusal([])
  end

  # The message has to name the addresses, because the remedy is manual and an operator
  # cannot do it against a count.
  it 'names the addresses and what has to happen to them' do
    refusal = Duplicates.refusal(['b@example.com', 'a@example.com'])

    assert_includes refusal, 'a@example.com, b@example.com'
    assert_includes refusal, 'resolved by hand'
  end
end

# Ownership is read out of the catalog rather than from a list written down, and this is the
# half that would go wrong silently if it were not. account_remember_keys refers to an
# account through its own `id` column rather than an `account_id`, so a hand-written list
# would have read the wrong column and called an account empty on the strength of it.
module Ownership
  def account
    DB[:accounts].insert(email: "#{SecureRandom.hex}@example.com", password_hash: 'x')
  end
end

describe 'the tables an account can own something in' do
  it 'finds every table that refers to an account' do
    tables = Duplicates.references(DB).map(&:first)

    assert_includes tables, :workouts
    assert_includes tables, :account_training_maxes
    assert_includes tables, :mcp_audit_log
  end

  # The column, not just the table -- this is the pair a hand-written list would have got
  # wrong, and getting it wrong means calling an account empty and deleting it.
  it 'reads account_remember_keys through its id column' do
    assert_includes Duplicates.references(DB), %i[account_remember_keys id]
  end
end

describe 'which accounts own something' do
  include Ownership

  it 'says a fresh account owns nothing' do
    assert_empty Duplicates.owned_ids(DB, [account])
  end

  it 'says an account with a workout owns something' do
    id = account
    DB[:workouts].insert(account_id: id, date: Time.now)

    assert_equal [id], Duplicates.owned_ids(DB, [id])
  end

  it 'tells apart the owner and the empty row of a pair' do
    owner = account
    empty = account
    DB[:workouts].insert(account_id: owner, date: Time.now)

    assert_equal [owner], Duplicates.owned_ids(DB, [owner, empty])
  end

  it 'asks nothing of the database for no accounts' do
    assert_empty Duplicates.owned_ids(DB, [])
  end
end

# The two shapes a narrower reading of "owns training" would have got wrong, and got wrong
# in the direction that deletes somebody's row.
describe 'ownership that is easy to miss' do
  include Ownership

  # An empty workout is still ownership. It is the exact shape the one non-empty row in
  # production had -- one workout, no sets, no name, no note -- and a rule that counted sets
  # instead of workouts would have called it empty and deleted the record somebody made.
  it 'counts a workout with no sets in it' do
    id = account
    DB[:workouts].insert(account_id: id, date: Time.now)

    refute_empty Duplicates.owned_ids(DB, [id])
  end

  # Reached through workouts rather than directly, which is why the references list does not
  # need to name the sets table. The exercise is one the library already holds rather than a
  # new one, because the teardown between tests keeps library rows on purpose and an inserted
  # one would outlive this file and be counted by the specs asserting the library's size.
  it 'counts an account whose only rows are sets under a workout' do
    id = account
    workout = DB[:workouts].insert(account_id: id, date: Time.now)
    DB[:sets].insert(workout_id: workout, exercise_id: DB[:exercises].first[:id], weight: 100, reps: 5)

    assert_equal [id], Duplicates.owned_ids(DB, [id])
  end
end

