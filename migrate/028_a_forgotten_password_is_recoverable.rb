# frozen_string_literal: true

# Somewhere to put a password reset token. #344.
#
# Until now a forgotten password lost the account outright. There was no reset flow, and the
# app said so in two places -- views/create-account.erb warns that a mistyped password means
# "an account created under a mistyped password is gone", and app.rb's rodauth block gives
# that as the reason the password-confirmation box was worth arguing about. Both of those
# notes describe a hole rather than a decision.
#
# It is worse than an inconvenience because of #345, which landed just before this: one email
# is now one account, so somebody who has lost their password can no longer even sign up
# again with the same address and start over. The two changes are only both right together.
#
# The shape is Rodauth's, matching account_remember_keys in 001 down to the Bignum primary
# key that is also the foreign key -- one row per account, replaced rather than accumulated,
# so a second request supersedes the first instead of leaving two live tokens.
#
# `email_last_sent` is what Rodauth rate-limits on. Without it a form that emails on submit is
# a way to send somebody a hundred emails, and the address is not even the sender's -- so the
# column is the difference between a reset form and a small mail bomb aimed at whoever's
# address gets typed in.
Sequel.migration do
  change do
    create_table(:account_password_reset_keys) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :deadline, null: false,
                          default: Sequel.date_add(Sequel::CURRENT_TIMESTAMP, days: 1)
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

