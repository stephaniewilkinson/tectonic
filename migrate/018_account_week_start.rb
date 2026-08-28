# frozen_string_literal: true

# Which day a week begins on, per account. #189.
#
# The calendar grid has always started on Sunday, and not by decision -- Calendar.bounds
# does a plain subtraction, `month - month.wday`, which is Sunday because Date#wday counts
# from Sunday. Most of the world reads a week as beginning on Monday, and the app had no
# way to say so.
#
# A Date#wday number rather than a name, which is the vocabulary program_days.weekday
# already uses: 0 is Sunday, 1 is Monday. Constrained to those two because they are the two
# a calendar grid can honestly start on -- a week beginning on Wednesday is not a preference
# anybody has, and leaving the column open would mean every reader handling a value nobody
# will ever store.
#
# Defaulted and not null, so every existing account keeps the grid it has and this arrives
# as something you may change rather than as a change made on your behalf.
#
# This is the half of #189 that stands on its own: it depends on nothing else in that issue,
# and the units half of it was dropped outright -- pounds everywhere, no kg -- so what is
# left beside this is the plate inventory moving onto the same page.
# up and down rather than change, because rubocop-sequel is right that a constraint written
# with =~ inside a change block is not something the migrator can reverse on its own.
Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :week_starts_on, Integer, null: false, default: 0
      add_constraint(:accounts_week_start_known) { week_starts_on =~ [0, 1] }
    end
  end

  down do
    alter_table(:accounts) do
      drop_constraint(:accounts_week_start_known)
      drop_column :week_starts_on
    end
  end
end

