# frozen_string_literal: true

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
# **It refuses to run rather than choosing a winner.** If two rows already share an address,
# one of them owns training somebody did, and which one survives is a question about a person
# rather than about data -- so this names them and stops. That is deliberately louder than a
# migration that quietly renamed the loser: a failed deploy is noticed, and the alternative
# is discovering months later that a session went somewhere unreachable.
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
  # for. The duplicate check above it is a read and needs no transaction of its own.
  no_transaction

  up do
    duplicated = from(:accounts).select_group(:email).having { count.function.* > 1 }.select_map(:email)
    unless duplicated.empty?
      raise Sequel::Error,
            "These addresses already have more than one account: #{duplicated.join(', ')}. " \
            'Each pair has to be resolved by hand before email can be made unique, because ' \
            'one of the two rows owns training that somebody did. Merge or remove them, then ' \
            'run this again.'
    end

    add_index :accounts, :email, unique: true, name: :accounts_email_key, concurrently: true
  end

  down do
    drop_index :accounts, :email, name: :accounts_email_key, concurrently: true
  end
end

