# frozen_string_literal: true

# Somewhere to record that an address has been proved, and a token to prove it with. #575.
#
# Signing up needs nothing but the form, so an address never had to exist, let alone belong
# to the person typing it. 410 accounts, 409 of which have never logged a set, and
# `reset_password` is enabled and really sends -- so every one of those addresses can be made
# to receive mail from this domain by anybody who knows it. That is a sending-reputation
# problem rather than a tidiness one, and it is the reason `verify_account` goes on.
#
# ## The status column, which is the whole risk of this change
#
# `accounts` has never had one. Rodauth's base defaults `skip_status_checks?` to true
# (`base.rb:74`), and that default is load-bearing here: `_new_account` leaves the column out
# of the insert (`create_account.rb:123-125`), `_account_from_login` skips the filter
# (`base.rb:837`), `_account_from_session` skips it (`base.rb:843`). The column is never read
# and never written, which is the only reason this app works without one.
#
# `verify_account` flips that default to false (`verify_account.rb:214-216`). The moment it
# appears in the enable list, all four of those paths turn on at once -- sign-up, login, and
# every authenticated request -- against a column that is not there. That is
# `PG::UndefinedColumn` on every request, not a degraded feature, which is why this migration
# has to land before the configuration change and why the two are written together.
#
# `Integer` rather than a boolean `verified` column, which nearly works and has one silent
# flaw: `base.rb:849` guards the verify-link lookup on `if status_id && ...`, and `false` is
# falsy in Ruby, so a `verified` of false would drop the unverified constraint from that
# lookup without saying anything. Rodauth's 1/2/3 convention has no falsy member.
#
# ## Why the default is 2 and not Rodauth's conventional 1
#
# This is the single line in this change whose failure mode is "nobody can log in", so the
# three reasons are worth writing down rather than remembering.
#
# The first is the deploy window. `preDeployCommand` runs this migration and then the old
# code keeps serving until the new version boots, so there is a stretch -- seconds, but real
# -- where a sign-up goes through the *old* configuration, which knows nothing about
# verification. With a default of 1 that account is created unverified with no row in
# `account_verification_keys`, and `verify_account_email_resend` returns nil without one
# (`verify_account.rb:177-183`), so the resend form silently does nothing for them, forever.
# A default of 2 makes that account an ordinary working one.
#
# The second is rollback. A default of 2 means rolling the configuration back leaves every
# row in the state the old code expects; a default of 1 means anything created under the new
# code is stranded the moment verification is switched off.
#
# The third is the suite: fifty-eight spec files insert accounts into this table directly,
# and every one of them would start producing an account that cannot log in.
#
# None of this weakens the feature, because Rodauth always sets the status explicitly on
# create -- `_new_account` writes `account_initial_status_value`, which `verify_account`
# overrides to the unverified value (`verify_account.rb:202-204`). The default is what
# governs rows nobody's Rodauth wrote, and every one of those is an account that already
# exists and has always been able to log in.
#
# The backfill below says the same thing a second time, against the rows rather than against
# the column. It is redundant with the default and deliberately so: `add_column` with a
# default fills existing rows on every Postgres this app has ever run on, but the sentence
# "every account that existed before today is open" is the one claim in this file that must
# not depend on a detail of how `ALTER TABLE` behaves.
#
# ## The key table
#
# Rodauth's shape, matching `account_password_reset_keys` in 028 down to the Bignum primary
# key that is also the foreign key: one row per account, replaced rather than accumulated, so
# a second request supersedes the first instead of leaving two live tokens. The columns are
# the ones `verify_account.rb:35-39` names.
#
# `requested_at` is not one of them. It belongs to `verify_account_grace_period`
# (`verify_account_grace_period.rb:9`), which this change deliberately does not enable -- a
# grace period would let an unverified account authorise an MCP client during the window, and
# would introduce a session that is logged in *and* unverified, which about ten routes
# calling `account_from_session[:id]` without a nil guard have never had to handle. The column
# is here anyway because it costs nothing now and costs a second migration later, and because
# the grace period is the obvious thing to reach for if verification turns out to be too
# strict in practice. It defaults rather than being written, since nothing writes it.
#
# There is no `deadline` here, unlike 028. A reset link is a live credential sitting in an
# inbox and has to expire; a verification link grants nothing at all until a password is
# chosen through it, and expiring it would strand somebody who read their email a day late
# behind a resend form they have to find first.
#
# ## An account may now exist with no password at all
#
# This is the other half of the change and the part that looks alarming written down. The
# address is confirmed and the password is chosen on the same page, the one the emailed link
# leads to -- so between signing up and clicking that link, the row has no credential.
# `migrate/001_schema.rb:37` declares `password_hash` `null: false`, so the column has to
# allow one.
#
# **A null hash fails closed**, which was measured rather than assumed. `base.rb:488` is
# `if hash = get_password_hash`, so a nil hash makes `password_match?` return nil and the
# login is refused with the ordinary "Invalid password" -- for an empty password, for any
# password, and whether the account is unconfirmed or open. There is no empty-string
# comparison and no nil-equals-nil hole to fall through. Writing the password later is a
# plain `update_account` on this column (`login_password_requirements_base.rb:67-70`), so
# nothing about the confirm page needs the constraint gone for any reason but the insert.
#
# ### Why not Rodauth's separate password-hash table, which is its own default
#
# Three reasons, and the third is on its own sufficient.
#
# That design exists so that the *database role* the application connects as cannot `SELECT`
# the hash -- the table is owned by another role and reached through a `SECURITY DEFINER`
# function. That is a role split, not a schema shape. This app connects to Render Postgres as
# the owning role and there is no second one, so moving the column would buy the shape of the
# protection without the protection.
#
# It would also mean migrating four hundred and ten existing hashes out of `accounts` in the
# same deploy as the status column -- on the one change in this system whose failure mode is
# "nobody can log in".
#
# And it does not work here at all. Dropping `account_password_hash_column` is what moving to
# the separate table means, and that makes `use_database_authentication_functions?` true on
# Postgres (`base.rb:787`), so every login calls the SQL functions `rodauth_get_salt` and
# `rodauth_valid_password_hash`. Neither exists in this database. That is
# `PG::UndefinedFunction` on every sign-in until somebody hand-writes two SECURITY DEFINER
# functions -- the alternative branch is one the gem marks `# :nocov:` itself. So "move it to
# the separate table" is not a smaller change that was passed over; it is a different project.
# If the role split is ever made, that is the migration to write, and it will be worth writing
# then for a reason this one cannot claim.
#
# ### The case this opens, which is worth knowing about
#
# An account that is open *and* hashless should not arise from any path here, but it is one
# `UPDATE` away by hand and it is what rolling the configuration back would leave behind. Such
# an account is not stuck: the reset form finds it, writes a key and mails a link, so a
# password can still be set. The one thing that goes wrong is the wording -- the reset email
# says "your current password still works", and for that person there is no current password.
Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :status_id, Integer, null: false, default: 2
      set_column_allow_null :password_hash
    end
    from(:accounts).update(status_id: 2)

    create_table(:account_verification_keys) do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :requested_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  # Written out rather than left to `change`, because the order matters: the key table
  # references `accounts`, so it goes before the column comes off. Rolling this back on a
  # database serving the new configuration would be an outage of its own -- the code would
  # ask for `status_id` and it would be gone -- so this is the second half of a rollback
  # whose first half is putting the old configuration back.
  #
  # **`password_hash` is deliberately left nullable**, so this is not a true inverse and says
  # so rather than pretending. Restoring `NOT NULL` would fail on exactly the rows a rollback
  # exists to survive: every account that signed up and had not yet clicked its link has no
  # hash, and `ALTER COLUMN ... SET NOT NULL` refuses while one of them is there. The two ways
  # to make it succeed are both worse than a permissive column. Deleting those accounts is a
  # migration that deletes people's rows, which is the one thing #575 says must not happen
  # without a deliberate decision; refusing to roll back is a rollback that does not work on
  # the day it is needed.
  #
  # Nothing writes a null there under the old configuration -- `create_account_set_password?`
  # is true again the moment `verify_account` leaves the enable list -- so the constraint is
  # guarding a path that no longer exists. Put it back by hand, once those rows have been
  # dealt with deliberately, with:
  #
  #   ALTER TABLE accounts ALTER COLUMN password_hash SET NOT NULL;
  down do
    drop_table(:account_verification_keys)
    alter_table(:accounts) do
      drop_column :status_id
    end
  end
end

