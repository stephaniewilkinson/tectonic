# frozen_string_literal: true

# Two columns for a feature that was never built. #197.
#
# workouts.photo and accounts.profile_picture have been in the schema since 001 and are
# written by nothing and read by nothing -- not by a form, not by a route, not by an MCP
# tool. They are the only two columns in this database that are dead at both ends.
#
# Both are bytea, which is the part that decides it. They were built to hold image bytes in
# Postgres, so functionalising them means taking on image storage: where the bytes live,
# what serves them, what size is refused, and -- for anything holding a URL instead -- the
# third-party fetch that took the Icon URL field off the exercise form in #199. That is a
# feature, not a gap, and not one wanted now.
#
# Worth naming the difference from exercises.icon_url, which #199 deliberately left with no
# UI writer: the MCP tools write that one and Exercise#icon reads it on every workout
# record, so it is live at both ends. These two are live at neither.
#
# **This deletes data.** If any row holds bytes, they go, and the down migration cannot
# bring them back -- it restores the columns empty. Nothing in the app has ever put bytes
# there, so any that exist were written by hand.
Sequel.migration do
  up do
    drop_column :workouts, :photo
    drop_column :accounts, :profile_picture
  end

  down do
    add_column :workouts, :photo, File
    add_column :accounts, :profile_picture, File
  end
end

