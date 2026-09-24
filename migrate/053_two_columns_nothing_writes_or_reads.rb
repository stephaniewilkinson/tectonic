# frozen_string_literal: true

# Two more columns dead at both ends -- written by nothing, read by nothing -- which is the
# shape #197 dropped `workouts.photo` and `accounts.profile_picture` for. #602, #607.
#
# ## `oauth_grants.access_type`
#
# rodauth-oauth owns it, and only behind `use_oauth_access_type?`, which defaults to false and
# which this app has never set. Every read and write of the column in the gem sits behind that
# flag, so every row holds the `'offline'` its own default put there and nothing has ever read
# it back. It sat between `created_at` and the PKCE columns in 001, all of which are live, and
# so it was a false lead for anyone tracing how a refresh token gets decided.
#
# **This drop holds only while `use_oauth_access_type?` is false.** Turning it on would have
# the gem write `'online'` into this column on the approval-prompt path and read it back when
# deciding whether to issue a refresh token, and it would find nothing there. Anyone enabling
# that flag needs this column back first; `down` below is exactly that column.
#
# That is the distinction from `account_login_change_keys.email_last_sent`, which also has no
# reference in this repo and is not dead: `verify_login_change` is enabled and rate-limits on
# it. The test is whether the feature that owns a column is on, not whether this repo names it.
#
# ## `withings_workouts.effective_seconds`
#
# 042 added it for Withings' `effduration`. #586 found that is not a field Withings has -- the
# name appears nowhere in the OpenAPI document behind their reference -- and stopped asking for
# it and writing it. It was null on every row before that and could never have been anything
# else, so nothing is lost. It waited for this migration only because 051 and 052 were held by
# branches that had not landed.
Sequel.migration do
  up do
    alter_table(:oauth_grants) { drop_column :access_type }
    alter_table(:withings_workouts) { drop_column :effective_seconds }
  end

  down do
    alter_table(:oauth_grants) { add_column :access_type, String, null: false, default: 'offline' }
    alter_table(:withings_workouts) { add_column :effective_seconds, Integer }
  end
end

