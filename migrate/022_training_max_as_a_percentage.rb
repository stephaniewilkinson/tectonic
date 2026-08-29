# frozen_string_literal: true

# A training max can say what it is a percentage of. #292.
#
# 020 stored one number and ProgramGenerator multiplied it by percent_of_max directly. That
# works for a lifter who does the arithmetic themselves, and it cannot express the thing
# 5/3/1 and its descendants actually ask you to say, which is two facts rather than one:
# *my squat is 500, and I train off 90% of it.*
#
# Collapsed to one, the 500 is nowhere. Three consequences, and the first is the one that
# bites:
#
# - the page cannot show "500 x 90% = 450", which is the display that catches a misentry. A
#   lifter who types 500 meaning the tested single sees no arithmetic and no clue that every
#   percentage in the block is now running about eleven percent hot.
# - re-testing means recomputing the discount by hand and retyping a derived number.
# - a Sheiko-style lifter programming off a competition max and a 5/3/1 lifter programming
#   off 90% of one are storing numbers on different scales in the same column, with nothing
#   recording which.
#
# **The default is the whole of why this is safe.** 100 reproduces the existing arithmetic
# exactly -- pounds * 100 / 100 is pounds -- so it is a mathematical no-op for every account
# that already has a row, and nobody's loads move on deploy. A 5/3/1 lifter enters 500 and
# 90; a Sheiko lifter enters a competition max and leaves it alone.
#
# Bounded 50 to 100 rather than reusing Bounds::PERCENT's 1 to 200. A training max above the
# max it is a percentage of is not a thing, and neither is one at 20% -- both are typos, and
# the column is the one place they cannot be typed past. The floor is generous on purpose:
# 5/3/1's own range is 85 to 90, and a very cautious return from injury might sit lower, so
# the bound refuses nonsense rather than expressing an opinion about programming.
#
# NOT NULL with a default rather than nullable, because "no percentage" and "100 percent"
# are the same instruction and two spellings of one fact is what every reader would then
# have to handle.
Sequel.migration do
  up do
    alter_table(:account_training_maxes) do
      add_column :train_at_percent, Integer, null: false, default: 100
      add_constraint(:account_training_maxes_percent_in_range) do
        Sequel.lit('train_at_percent BETWEEN 50 AND 100')
      end
    end
  end

  down do
    alter_table(:account_training_maxes) do
      drop_constraint(:account_training_maxes_percent_in_range)
      drop_column :train_at_percent
    end
  end
end

