# frozen_string_literal: true

# What Rodauth's lockout feature keeps: a count of wrong passwords per account, and a lock with
# an unlock key and a deadline once the count passes the limit. Found in a security pass,
# 2026-09-25: sign-in had no limit on guesses at all.
#
# Two tables, as the feature expects them and nothing added. Rows are one per account and are
# deleted by Rodauth when a login succeeds or a lock is lifted, so neither grows.
Sequel.migration do
  change do
    create_table(:account_login_failures) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum, on_delete: :cascade
      Integer :number, null: false, default: 1
    end

    create_table(:account_lockouts) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum, on_delete: :cascade
      String :key, null: false
      # The hour lives here, in the default, which is where Rodauth reads a lockout's end from
      # on Postgres -- the same way 028 gives a reset link its day.
      DateTime :deadline, null: false, default: Sequel.date_add(Sequel::CURRENT_TIMESTAMP, hours: 1)
      DateTime :email_last_sent
    end
  end
end

