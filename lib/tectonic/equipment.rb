# frozen_string_literal: true

require_relative 'db'
require_relative 'plates'
require_relative 'rounding'

class Tectonic < Roda
  # What one account has to lift with: a bar, and pairs of plates. Everything the app
  # calculates -- warmups, ascending ramps, rep conversion, percentage loads, the per-side
  # label, and how much a programme adds after a good week -- is downstream of these two
  # facts, and they used to be constants.
  #
  # The whole of that is threaded through the app as one number where it can be. The
  # smallest jump a bar can make is a property of the rack, and `Rounding.to_increment`
  # already took an increment, so most callers need the number rather than the inventory.
  class Equipment
    # What a rack looks like when nobody has said otherwise: a men's bar and the plates
    # the app assumed before it asked. Two pairs of each is enough for any weight these
    # denominations can express without being a claim about a particular garage.
    DEFAULT_BAR = 45
    DEFAULT_PLATES = { 45 => 2, 25 => 2, 10 => 2, 5 => 2, 2.5 => 2 }.freeze
    # The denominations the form offers. Not a limit on what can be stored -- the column
    # takes any weight and an MCP tool or a migration may write others -- just the ones
    # worth putting in front of someone, from a full-size plate down to the micro plates
    # that make a 2 lb jump possible.
    OFFERED = [45, 35, 25, 20, 15, 10, 5, 2.5, 1.25, 1].freeze

    attr_reader :bar_weight, :pairs

    # `pairs` maps a denomination to how many pairs of it the account owns.
    def initialize(bar_weight:, pairs:)
      @bar_weight = bar_weight
      @pairs = pairs
    end

    def self.for_account(account_id)
      owned = DB[:account_plates].where(account_id:).to_hash(:denomination, :pairs)
      bar = DB[:accounts].where(id: account_id).get(:bar_weight) || DEFAULT_BAR
      new(bar_weight: bar, pairs: owned.empty? ? DEFAULT_PLATES : numeric_keys(owned))
    end

    # An account that has never said what it owns lifts on the default rack rather than on
    # an empty one, so nothing breaks for anyone who does not care.
    def self.default
      new(bar_weight: DEFAULT_BAR, pairs: DEFAULT_PLATES)
    end

    # BigDecimal comes back from the column; the arithmetic downstream wants a plain
    # number, and 2.5 has to stay 2.5 rather than becoming 2.
    def self.numeric_keys(owned)
      owned.transform_keys { |denomination| Plates.numeric(denomination.to_r) }
    end

    # The smallest weight change this rack can make: the lightest plate, on both sides.
    # This is the number a progression steps by and everything rounds to, which is why
    # adding a pair of 1 lb plates changes the programme without changing any code.
    def increment
      lightest = pairs.keys.min
      return Rounding::INCREMENT unless lightest

      Plates.numeric(lightest.to_r * 2)
    end

    # Rounds a calculated weight to something this rack can actually load.
    def round(weight)
      Rounding.to_increment(weight, increment:)
    end

    # The per-side breakdown, or nil when this rack cannot make the weight.
    def per_side(total)
      Plates.per_side(total, bar_weight:, inventory: pairs)
    end

    def label(total)
      Plates.label(per_side(total))
    end

    # The denominations owned, heaviest first, for a view or a form.
    def denominations
      pairs.keys.sort.reverse
    end

    # Replaces what an account owns in one go. A form submits the whole rack rather than
    # editing a row at a time, because the rack is one fact -- and a partial update would
    # leave the increment reading off plates the lifter had just removed.
    #
    # `plates` maps a denomination to pairs, as strings from a form. A denomination with
    # no pairs is simply not owned, which is how a plate is taken away.
    def self.replace(account_id, bar_weight:, plates:)
      DB.transaction do
        bar = Integer(bar_weight.to_s, 10, exception: false)
        DB[:accounts].where(id: account_id).update(bar_weight: bar) if bar&.positive?
        DB[:account_plates].where(account_id:).delete
        owned(plates).each do |denomination, count|
          DB[:account_plates].insert(account_id:, denomination:, pairs: count)
        end
      end
    end

    # The rows worth keeping from a submitted form: a positive denomination with at least
    # one pair. Anything unparseable is not a plate and is dropped rather than guessed at.
    def self.owned(plates)
      plates.to_h.filter_map do |denomination, count|
        weight = Float(denomination.to_s, exception: false)
        pairs = Integer(count.to_s, 10, exception: false)
        [weight, pairs] if weight&.positive? && pairs&.positive?
      end
    end
  end
end

