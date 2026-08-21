# frozen_string_literal: true

Sequel.migration do
  # What an account actually has to lift with. Every weight the app calculates has until
  # now assumed one rack -- a 45 lb bar and plates down to 2.5, which makes 5 lb the
  # smallest jump anyone can make -- and that assumption reached warmups, ascending
  # ramps, rep conversion, percentage loads and the per-side plate label alike.
  #
  # It is wrong in both directions. Somebody with 1 lb plates can make 2 lb jumps and was
  # never offered them; somebody on a 35 lb bar got warmups and plate math out by 10 lb at
  # every rung; somebody whose rack stops at 5s was told to load weights they cannot make.
  #
  # The bar lives on the account. The plates are rows because a pair is a thing you own a
  # number of: `per_side` assumed unlimited plates of every size, so one pair of 1 lb
  # plates would happily be prescribed four times.
  change do
    add_column :accounts, :bar_weight, Integer, null: false, default: 45

    create_table(:account_plates) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      # Half-pound plates exist, and a 1.25 is the usual micro plate, so the denomination
      # cannot be an integer. Numeric rather than float: these are compared and summed to
      # decide whether a weight is loadable at all, and 2.5 + 2.5 has to be exactly 5.
      BigDecimal :denomination, size: [6, 2], null: false
      # Pairs, not plates: a barbell is loaded symmetrically, and counting singles would
      # invite a rack that can make an odd weight it physically cannot.
      Integer :pairs, null: false, default: 1

      unique %i[account_id denomination]
      index :account_id
    end
  end
end

