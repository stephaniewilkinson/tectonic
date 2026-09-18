# frozen_string_literal: true

# Somewhere to put a bodyweight, and somewhere to keep the permission to fetch one. #472.
#
# ## Two tables, because they are two different lifetimes
#
# A measurement is permanent and a token is not. Tokens expire, get refreshed, and are
# revoked the moment a lifter disconnects -- and disconnecting must not delete a year of
# bodyweight readings. Keeping them in one row would make "stop syncing" and "forget my
# weight" the same button.
#
# ## `measured_at` is not `created_at`, and that is the whole point
#
# Health data arrives retroactively. Last night's sleep may not land until midday; a scale
# reading taken at 06:40 is fetched at 13:00. So when a reading *happened* is a column, and
# when the row appeared is not the same fact. Sessions join to it by date rather than by a
# foreign key for the same reason: the workout and the weigh-in are two things that happened
# on one day, not one thing with two halves.
#
# ## The unique index is what makes re-fetching safe
#
# Polling a window re-reads measurements already stored -- deliberately, because a window that
# only ever moved forward would lose anything that arrived late, which is most of the point of
# `measured_at`. `[source, external_id]` makes the second read a no-op instead of a duplicate,
# and it is a constraint rather than a convention because the alternative is a chart with every
# point drawn twice.
#
# `source` is here from the start though only Withings writes today. A metric is only
# comparable to another from the same instrument -- a scale's body-fat figure and a caliper's
# are different measurements wearing one name -- so a reader that cannot tell them apart would
# average two things that do not average. #473 is the other source this anticipates.
Sequel.migration do
  change do
    create_table(:health_metrics) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade
      # Free text rather than an enum, because the set grows with every instrument and a
      # migration per metric is a migration nobody will write. The reading tools name the
      # ones they understand.
      String :metric, null: false
      # Three decimal places: a scale reports 81.448 kg, and rounding on the way in would
      # make a trend over a fortnight read as a staircase.
      BigDecimal :value, size: [10, 3], null: false
      # Stored as given rather than converted. A kilogram converted to pounds on the way in is
      # a number the lifter never saw, and converting back for display loses a little more
      # each time.
      String :unit, null: false
      DateTime :measured_at, null: false
      String :source, null: false
      # The source's own id. Nullable because a hand-entered reading has none, which is also
      # why the unique index below tolerates nulls -- two manual weigh-ins on one day are two
      # readings, not a conflict.
      String :external_id
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      index %i[account_id metric measured_at]
      index %i[source external_id], unique: true
    end

    # The permission to fetch, and nothing about what was fetched.
    create_table(:account_withings) do
      primary_key :id
      # One connection per account. The unique index is what makes reconnecting an update
      # rather than a second row quietly racing the first.
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade, unique: true
      String :access_token, null: false
      String :refresh_token, null: false
      # When the access token dies. Withings' are short-lived -- hours, not days -- so
      # everything that calls the API has to be willing to refresh first, and cannot do that
      # without knowing when.
      DateTime :expires_at, null: false
      # Withings' own id for the person. Kept because a refresh returns it and because it is
      # the only way to notice that an account has been reconnected to a *different* Withings
      # login, which would otherwise silently mix two people's measurements.
      String :withings_user_id
      DateTime :connected_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      # When a fetch last succeeded, so the poller knows where to resume and the page can say
      # how fresh the numbers are. Null until the first one.
      DateTime :synced_at
    end
  end
end

