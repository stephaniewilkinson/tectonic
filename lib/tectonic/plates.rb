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
      remaining = beyond_the_bar(total, bar_weight)
      return nil if remaining.nil?

      load(remaining, stock(inventory))
    end

    # The weight nearest `total` that this rack can actually load, as [weight, breakdown],
    # or nil for a total under the bar, which no arrangement of plates reaches.
    #
    # This exists because `per_side` answers nil for a weight the rack cannot make, and
    # nil is the one answer that cannot be shown to somebody standing at the bar: no plate
    # math reads as nothing to put on. Naming the nearest weight the rack can make, and
    # what it takes, is the answer to the question actually being asked, which is not
    # "what does 124 need" but "what do I load".
    #
    # A tie goes to the lighter bar. Overshooting a prescription adds work nobody asked
    # for and can turn a planned single into a miss; undershooting by the same amount
    # costs a little stimulus and nothing else, so the two errors are not worth the same.
    def closest(total, bar_weight: BAR_WEIGHT, inventory: DEFAULT_INVENTORY)
      remaining = beyond_the_bar(total, bar_weight)
      return nil if remaining.nil?

      plates = stock(inventory)
      best = reachable(remaining, plates).min_by { |sum| [(sum - remaining).abs, sum] }
      [numeric(bar_weight.to_r + (best * 2)), load(best, plates)]
    end

    # Half of whatever goes on the bar past the bar itself, or nil when the total is
    # lighter than the bar and there is no such thing.
    def beyond_the_bar(total, bar_weight)
      return nil if total.nil?

      remaining = (total.to_r - bar_weight.to_r) / 2
      remaining.negative? ? nil : remaining
    end

    # Every per-side load this rack can make, in no particular order, always including the
    # bare bar's zero. A rack is small enough to enumerate outright: two pairs each of five
    # denominations is 243 arrangements, and `uniq` collapses those to a few dozen distinct
    # weights, which is why this stays cheap as denominations are added.
    #
    # No more of a plate is counted than it takes to reach `target`, since one more than
    # that already overshoots and can never be the nearest. That cap is also what keeps a
    # rack given as a bare list -- as many of each as the weight needs -- from enumerating
    # forever against an infinite pair count.
    def reachable(target, plates)
      plates.reduce([0r]) do |sums, (plate, pairs)|
        most = [pairs, (target / plate).ceil].min
        (0..most).flat_map { |count| sums.map { |sum| sum + (plate * count) } }.uniq
      end
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

