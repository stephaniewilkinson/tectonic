# frozen_string_literal: true

# The app runs on the server's clock, which is already tomorrow every US evening. #349.
#
# No timezone existed anywhere -- not per account, not in config -- so every "today" was the
# server's today, and the server is UTC. A lifter in New York opening the app at 8:30pm Monday
# is, to this app, acting on Tuesday.
#
# Three failures follow from that one cause, all of them during the evening hours when most
# people lift:
#
#   * signing in looks for today's session, misses Monday's, and lands on the new-workout stub
#     instead of the session they came to do
#   * asking an assistant to log "today" opens a second, empty workout beside Monday's real
#     one -- the exact duplicate create_workout's own description promises not to create
#   * a Monday evening session in progress reads as skipped while it is being lifted
#
# The suite could not see any of it, because both sides of every assertion used the same clock.
#
# **An IANA name rather than an offset.** "America/New_York" survives the clocks going back;
# -0500 is true for half the year and wrong for the other half, and a stored offset would have
# to be corrected twice a year by somebody who has no reason to think about it. tzinfo is
# already in the bundle -- rodauth-oauth depends on activesupport, which depends on it -- so
# this needs no new dependency.
#
# **Nullable, and null means UTC.** That is exactly today's behaviour, so no existing account
# changes the day it is on until somebody sets one, and an account created before this reads
# the same as it did the moment before the migration ran. The alternative -- defaulting every
# existing row to some guess about where its owner is -- would move sessions for people who
# never asked for it.
#
# **Not validated in the schema.** A check constraint would have to carry a list of zone names
# and would be wrong the next time a country changed its mind, which happens several times a
# year. The list belongs where it can be reloaded with the gem, so Clock refuses a name it
# cannot resolve and the settings form offers a list rather than a free text box.
Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :time_zone, String
    end
  end

  down do
    alter_table(:accounts) do
      drop_column :time_zone
    end
  end
end

