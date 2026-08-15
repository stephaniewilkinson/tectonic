# frozen_string_literal: true

require 'roda'

class Tectonic < Roda
  # Per-side plate math for a loaded barbell. Plates are assumed to be available
  # in whatever quantity a lift needs; inventory lists which denominations exist,
  # not how many of each are in the rack.
  module Plates
    BAR_WEIGHT = 45
    # A home gym without 35s. Pass an inventory to match a different rack.
    DEFAULT_INVENTORY = [45, 25, 10, 5, 2.5].freeze

    module_function

    # Returns [[plate, count], ...] heaviest first, [] for an empty bar, or nil
    # when the weight cannot be loaded from this inventory at all.
    def per_side(total, bar_weight: BAR_WEIGHT, inventory: DEFAULT_INVENTORY)
      return nil if total.nil?

      remaining = (total.to_r - bar_weight.to_r) / 2
      return nil if remaining.negative?

      load(remaining, inventory.map(&:to_r).uniq.sort.reverse)
    end

    # Depth first, heaviest plate first and most of it first, so the first exact
    # match found is also the one using the fewest plates. Backtracks instead of
    # giving up, so a rack like 45/35/20 still loads weights that a purely greedy
    # walk would wrongly call impossible.
    def load(remaining, plates)
      return [] if remaining.zero?
      return nil if plates.empty?

      plate, *rest = plates
      (remaining / plate).floor.downto(0) do |count|
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