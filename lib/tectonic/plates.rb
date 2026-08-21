# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  # Per-side plate math for a loaded barbell. An inventory says which denominations
  # exist and how many pairs of each are in the rack: owning one pair of 1 lb plates
  # and being told to load four of them is not a rack anybody has.
  module Plates
    BAR_WEIGHT = 45
    # A home gym without 35s, two pairs of each. Pass an inventory for a different rack.
    DEFAULT_INVENTORY = { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2 }.freeze

    module_function

    # Returns [[plate, count], ...] heaviest first, [] for an empty bar, or nil when the
    # weight cannot be loaded from this inventory at all. `inventory` maps a denomination
    # to the pairs owned; a bare list is read as one pair of each.
    def per_side(total, bar_weight: BAR_WEIGHT, inventory: DEFAULT_INVENTORY)
      return nil if total.nil?

      remaining = (total.to_r - bar_weight.to_r) / 2
      return nil if remaining.negative?

      load(remaining, stock(inventory))
    end

    # [[denomination, pairs], ...] heaviest first. A hash states how many pairs of each
    # the rack holds; a bare list states only which denominations exist, and says nothing
    # about how many, so it means as many as the weight needs. That is what the list form
    # has always meant, and a rack described that way should keep loading what it did.
    def stock(inventory)
      counted = inventory.is_a?(Hash) ? inventory : inventory.to_h { |plate| [plate, Float::INFINITY] }
      counted.map { |plate, pairs| [plate.to_r, pairs] }.uniq(&:first).sort_by(&:first).reverse
    end

    # Depth first, heaviest plate first and most of it first, so the first exact
    # match found is also the one using the fewest plates. Backtracks instead of
    # giving up, so a rack like 45/35/20 still loads weights that a purely greedy
    # walk would wrongly call impossible. The count is capped by the pairs owned,
    # which is what keeps it from prescribing plates that are not in the rack.
    def load(remaining, plates)
      return [] if remaining.zero?
      return nil if plates.empty?

      (plate, pairs), *rest = plates
      [(remaining / plate).floor, pairs].min.downto(0) do |count|
        loaded = load(remaining - (plate * count), rest)
        next unless loaded

        return count.zero? ? loaded : [[numeric(plate), count], *loaded]
      end
      nil
    end

    # "1×25 1×10" for the view, an em dash for a bare bar.
    def label(breakdown)
      return '' if breakdown.nil?
      return '—' if breakdown.empty?

      breakdown.map { |plate, count| "#{count}×#{plate}" }.join(' ')
    end

    # Rationals keep the 2.5s exact through the arithmetic; weights come back out
    # as 45 rather than (45/1), and 2.5 rather than (5/2).
    def numeric(value)
      value.denominator == 1 ? value.numerator : value.to_f
    end
  end
end

