# frozen_string_literal: true

# A creation date that moves, and the removal of two that never did. #574.
#
# `accounts.created_on` and `workouts.created_on` were declared `default: Time.now.utc`.
# That reads like a clock and is not one: Sequel evaluates the expression once, while the
# migration is running, and puts the instant it got into the column as a literal. Production's
# defaults are `'2023-06-16 04:03:51.973907'` and `'2023-06-16 04:03:52.814183'`, so every row
# written since has taken the constant. All 410 accounts and all 54 workouts say they were
# created on the same June morning three years ago. Not most of them; all of them.
#
# 001 spotted this and its comment says so -- the squashed baseline declares all three of these
# columns `Sequel::CURRENT_TIMESTAMP`, which is what the original declaration was reaching for.
# That correction reached every database built from 001 and no database that predates it.
# Production carries the baseline's schema but was *stamped* at the baseline's version rather
# than rebuilt from the file, which is the only safe thing to do with a squash and is exactly
# why the fix never arrived. The lesson outlives this column: **a schema correction that lives
# only in a squashed baseline does not reach any database that predates the squash.** It needs
# a migration of its own, which is this one.
#
# ## The two columns are not the same case, and get opposite treatments
#
# `workouts.created_on` is pure redundancy. `workouts.created_at` sits beside it, has always
# defaulted to CURRENT_TIMESTAMP, and disagrees with `created_on` on 36 of the 54 rows --
# precisely because it is the honest one. Nothing in lib, app.rb or views has ever read
# `created_on`. So it goes, with nothing put in its place: there is no information here to
# preserve, and the column that already answers this question keeps answering it.
#
# `accounts.created_on` is the only creation timestamp an account has. There is no
# `accounts.created_at`. Dropping it alone would leave the app unable to say when any of its
# accounts was created -- worthless as the values are, the question is worth being able to ask
# of a beta. So this one is replaced rather than deleted.
#
# ## The backfill this deliberately does not do
#
# **Nothing is written into `accounts.created_at` for the accounts that already exist.** They
# come out of this migration null, and null here means "created before anybody was recording
# it".
#
# There is no honest alternative. `created_on` cannot supply a date, because it is the same
# instant for all 410 rows -- copying it across would carry the bug into the new column and
# dress it as data. Nothing else in the schema knows: an account's oldest workout or grant
# would date the ones that have training behind them and say nothing about the rest, and
# "first thing they did" is a different fact from "when they signed up" even where it exists.
# Analytics can see that the bulk of these accounts arrived between 9 and 23 September 2026,
# and that is an aggregate; it cannot say which account arrived on which day, which is the only
# thing a per-row column could truthfully hold.
#
# So the choice is between a null and an invention, and the invention is worse than the bug.
# 410 rows all reading 2023-06-16 are at least visibly broken -- that is how #574 was found. If
# every one of them were stamped with today, they would read as 410 people signing up on the
# afternoon a migration ran: wrong, plausible, and permanent, with nothing left anywhere to
# contradict it. A fabricated fact dressed as a record is not a smaller problem than an obvious
# lie. It is the same problem with the evidence removed.
#
# This is 014's reasoning applied to a column that already exists: nullable and unwritten, so
# what arrives is something new to say rather than a claim made retroactively about rows nobody
# asked. What it costs is that anything reporting an account's age has to handle a null instead
# of assuming a date -- the app has nothing that reads this today, and whatever reads it next
# inherits the obligation. Null is not a gap in this column. It is the answer.
#
# ## Why the column is added without its default and given one afterwards
#
# The obvious spelling -- `add_column :created_at, DateTime, default: Sequel::CURRENT_TIMESTAMP`
# -- reproduces the bug it is fixing. Postgres fills existing rows when a column arrives with a
# default, and since CURRENT_TIMESTAMP is stable within a statement every one of those 410 rows
# would get the *same* instant: a new frozen timestamp, three years newer than the old one and
# exactly as untrue. Measured on Postgres 17 rather than assumed; two pre-existing rows came
# back carrying one identical stamp to the microsecond.
#
# `ADD COLUMN` with no default leaves them null, and `SET DEFAULT` afterwards touches nothing
# already written and applies to every insert from here on. Two statements, because the
# difference between them is the whole decision above.
#
# ## `workouts.date`, corrected in the same pass
#
# It carries a frozen literal for the same reason, and it is harmless today only because every
# writer supplies a date. It is a trap for the first insert that does not -- a session filed in
# June 2023 by a writer that simply said nothing about when it happened. Corrected here rather
# than left for the person who trips it, and on a database built from 001 this line is a no-op.
#
# ## Down
#
# Reversible, and honestly so. It puts both columns back as 001 declares them -- `NOT NULL`
# defaulting to CURRENT_TIMESTAMP -- and drops `accounts.created_at`. What it cannot do is
# restore the frozen literals, and it deliberately does not try: those instants were never in
# any migration, only in one database's history, and a `down` that recreated a broken default
# would be reintroducing the defect on purpose. It also cannot bring back a creation date it
# never had, so rolling back stamps every existing account with the instant of the rollback --
# `NOT NULL` leaves no other choice, and it is the same fabrication argued against above,
# which is worth knowing before rolling back rather than after.
Sequel.migration do
  up do
    alter_table(:workouts) do
      drop_column :created_on
      set_column_default :date, Sequel::CURRENT_TIMESTAMP
    end

    alter_table(:accounts) do
      add_column :created_at, DateTime
      drop_column :created_on
    end

    # Separate, and separate on purpose: see above. Adding the column with this default
    # would stamp all 410 existing accounts with one invented instant.
    alter_table(:accounts) do
      set_column_default :created_at, Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    alter_table(:accounts) do
      add_column :created_on, DateTime, null: false, default: Sequel::CURRENT_TIMESTAMP
      drop_column :created_at
    end

    alter_table(:workouts) do
      add_column :created_on, DateTime, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end

