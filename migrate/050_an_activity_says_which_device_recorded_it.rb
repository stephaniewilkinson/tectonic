# frozen_string_literal: true

# Somewhere to put the device that recorded an activity. #579.
#
# ## It has been arriving all along
#
# `getworkouts` returns `deviceid`, `model`, `model_id` and `date` on every workout object
# without being asked for any of them -- they are not `data_fields`, so unlike the calories
# and the three heart rates in 042 they cost no parameter, no extra request and no scope.
# `WithingsWorkouts.columns` read five of the fields on the response and dropped the rest,
# and this is the one of the dropped ones worth a column.
#
# What makes it worth one is that it answers a question nothing else here can. #579 spent
# most of its length on metrics that are behind a paid biomarker plan or a specific watch --
# HRV on a ScanWatch 2, SpO2, core temperature -- and ran into the same wall every time:
# **an unentitled field comes back absent, which is indistinguishable from a device that
# recorded nothing.** The only way to tell those apart is to know what the device is. Today
# that is a guess; with this column it is a query, on rows that are already stored.
#
# It is also the cheap half of a question that otherwise needs a scope we do not hold.
# Turning a `deviceid` into a device means User v2 - Getdevice, which needs `user.info`, and
# adding a scope makes every lifter who has already connected reconnect. `model` is on the
# workout row, so that never has to happen. #579 recommends writing that down next to
# `SCOPES` as a deliberate choice rather than a limitation, and this is the column that makes
# it one.
#
# ## Nullable, because a session is not always a device
#
# `attrib` 2 is an activity somebody typed into the Withings app afterwards, and a typed
# activity has no instrument to name. Null is what that is. Withings numbers their models
# from 1, so there is no in-band value meaning "none" to press into service, and
# `WithingsWorkouts.columns` takes care not to let `nil.to_i` turn an absent model into a 0
# that reads as a real one.
#
# ## The integer, and not a name for it
#
# Stored as Withings' number and nothing else. The same reference that carries the category
# table carries a model table -- 59 is an Activite Steel HR Sport Edition, 1058 is an Apple
# Watch reporting through HealthKit, and there are about forty of them -- but resolving it on
# the way in would freeze today's reading of somebody else's growing list into stored data,
# which is the argument 042 already made for keeping `category` as an integer. It is the same
# argument and it has not got weaker: Withings ship new watches, and a row written last year
# under a name would go on saying that name after they corrected it.
#
# Naming a model is a separate decision with its own source, and it is not needed for the
# thing this column exists for. "Is this account's watch capable of producing HRV" is
# answered by a set of model numbers, and a set of numbers is a constant in Ruby rather than
# a table in Postgres.
#
# ## Indexed by nothing
#
# Deliberately. Nothing reads this yet, and the reads it is for -- "what models has this
# account ever recorded with" -- are over one account's rows, which `[account_id, started_at]`
# from 042 already narrows to a handful. An index chosen before there is a query to serve is
# an index that turns out to be on the wrong column.
Sequel.migration do
  change do
    alter_table(:withings_workouts) do
      # Withings' `model`: the integer naming the device that recorded this activity. Null
      # where there was no device, which is an activity entered by hand. Not a foreign key
      # to anything, and not resolved to a name -- see the file comment above.
      add_column :model, Integer
    end
  end
end

