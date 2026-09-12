# frozen_string_literal: true

require_relative '../lib/tectonic/duplicate_accounts'

# One mailbox, one account. #345.
#
# Nothing enforced uniqueness on `accounts.email`, so the same address could sign up twice
# and both succeeded. Login then always resolved to the first row, so the second person got
# "wrong password" forever -- and with no reset flow in this app, there was no way out of it.
#
# The shape of it, from the issue: sign up on your phone, forget, sign up again on a laptop.
# The laptop account works until you log out. After that the address only ever reaches the
# first, empty account, and the training logged against the second is unreachable while
# still being there.
#
# Every other table with a uniqueness rule has one -- `account_training_maxes` and
# `account_goals` on (account_id, exercise_id), `exercises` on the library name. This one
# was simply missed.
#
# **It clears the duplicates that own nothing, and refuses on the ones that do.** The rule
# and the reasoning behind it are in `Tectonic::DuplicateAccounts`; this end of it is the
# reading and the writing. A row owning nothing is a failed second sign-up rather than
# somebody's training, so deleting it costs nobody anything and the deploy is not worth
# stopping for it. A pair that both own training is the case worth stopping for, and still
# does, by name.
#
# Case is left alone, and that is a known remaining gap rather than an oversight.
# `Foo@example.com` and `foo@example.com` are one mailbox and would still make two rows.
# Closing it means normalising on write *and* on the login lookup, and doing only the first
# would lock out every existing account whose stored address has a capital in it. That is a
# change worth making deliberately, against a look at what is actually stored, rather than
# folded into this one.
Sequel.migration do
  # CONCURRENTLY, following 017 and 023, so the index is built without holding a write lock
  # on accounts -- and it cannot run inside a transaction, which is what no_transaction is
  # for. The reads and the deletes below need no transaction of their own: each address is
  # settled independently, and a half-finished run leaves a database this migration can be
  # run against again.
  no_transaction

  up do
    deletions, unresolved = Tectonic::DuplicateAccounts.plan(Tectonic::DuplicateAccounts.duplicates(self))
    refusal = Tectonic::DuplicateAccounts.refusal(unresolved)
    raise Sequel::Error, refusal if refusal

    # Said out loud rather than done silently. These rows are gone after this, and the deploy
    # log is the only place that will ever record which ones they were.
    unless deletions.empty?
      puts "Removing #{deletions.length} duplicate account(s) owning nothing: #{deletions.sort.join(', ')}"
      from(:accounts).where(id: deletions).delete
    end

    add_index :accounts, :email, unique: true, name: :accounts_email_key, concurrently: true
  end

  down do
    drop_index :accounts, :email, name: :accounts_email_key, concurrently: true
  end
end

