# frozen_string_literal: true

# Dumbbells are their own rack. #369.
#
# 007 asked an account what plates it owns, and every weight this app writes has been rounded
# to what that rack can build ever since. It asked about one rack, and most people who train
# at home have two.
#
# What stands in for the second one today is `Equipment::DUMBBELL_INCREMENT`, a constant of 5,
# and #259 was honest about what that is: "an assumption rather than an inventory... an account
# with adjustable dumbbells that micro-load is not served by this, and is not served by
# anything else here either -- that wants a second inventory, which is a bigger thing than a
# rounding rule." This is that second inventory.
#
# **Why the constant is not good enough.** A fixed rack really does run 5, 10, 15 and up in
# fives, so the assumption is right for a commercial gym and right for most garages. It is
# wrong in both directions for an adjustable set: a pair of Powerblocks steps in 2.5 at the
# bottom, so a prescription of 27.5 is perfectly loadable and gets rounded away to 25; and a
# plate-loaded handle with only 5s and 10s on the shelf cannot make 22.5 at all, which the
# constant cheerfully prescribes.
#
# ## The shape is 007's, deliberately
#
# A handle weight on the account, and a table of denomination-to-pairs beside it. That is the
# same pair of facts a barbell rack is described by, and it is the same arithmetic: a dumbbell
# is loaded at both ends the way a bar is loaded at both sides, so "pairs" means the same thing
# and `Plates.totals` can answer for either without knowing which it is looking at.
#
# `pairs` is **per dumbbell**, not across the two. Adjustable sets are sold and stored as a
# pair of identical handles with a shared plate set, and a lifter counting what is on the shelf
# is counting what goes on one dumbbell -- "I have four 5s" means two a side, which is two
# pairs. Counting across both would make every number on the form twice what anybody would
# write down.
#
# ## Null means "the same as before"
#
# `dumbbell_handle_weight` is nullable and null is the ordinary case: a fixed rack, described
# by the constant, exactly as every account is described today. There is no default, because a
# default would be a claim that every account has adjustable dumbbells, and the form that
# writes this is the only place anybody can say so.
#
# So nothing changes for anybody until they fill it in, which is the same promise 007 made and
# the reason `DEFAULT_PLATES` exists.
#
# Numeric rather than integer for the same reason 007 gave about denominations: handles are
# 2.5 and 5 lb as often as they are whole numbers, and these values are summed to decide
# whether a weight is loadable at all.
Sequel.migration do
  change do
    add_column :accounts, :dumbbell_handle_weight, BigDecimal, size: [6, 2]

    create_table(:account_dumbbell_plates) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      BigDecimal :denomination, size: [6, 2], null: false
      # Pairs per dumbbell: one pair is one plate on each end. The same meaning `pairs` has
      # on account_plates, which is what lets one enumeration answer for both racks.
      Integer :pairs, null: false, default: 1

      unique %i[account_id denomination]
      index :account_id
    end
  end
end

