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

    # The nearest weight this rack can actually load.
    #
    # This is what `round` said it did and did not. It put a weight on a multiple of
    # `increment`, and a multiple of the increment is a different claim: `increment` reads
    # `pairs.keys.min` and throws the counts away, so it answers "what is the smallest step
    # this rack has a plate for" where loading asks "what can this rack build". A rack with
    # one pair of 1 lb plates has an increment of 2, which admits 124 -- 39.5 a side, needing
    # two pairs of 1s -- and the plate math could then only answer nil to a weight the
    # generator had just written. That is #140, and it ran both ways: the same rack could
    # not be prescribed 47, which it loads with a single pair, because 47 is not a multiple
    # of 2.
    #
    # No increment can fix that, which is why this does not try to pick a better one.
    # Whether a weight is loadable is a question about subsets of the rack, not about
    # divisibility, and only the enumeration answers it.
    #
    # A tie goes to the lighter weight, following Plates.closest: overshooting a
    # prescription adds work nobody asked for and can turn a planned single into a miss,
    # where undershooting by the same amount costs a little stimulus and nothing else.
    #
    # `is_barbell` is not decoration. A machine stack or a dumbbell is not loaded from this
    # rack at all, and putting its weight through barbell plate math would be a new wrong
    # answer in place of the old one, so those keep the increment rounding they had.
    def loadable(weight, is_barbell: true)
      return weight if weight.nil?
      return Rounding.to_increment(weight, increment:) unless is_barbell
      return Rounding.to_increment(weight, increment:) if loadable_totals.empty?

      loadable_totals.min_by { |total| [(total - weight).abs, total] }
    end

    # How this rack loads, for the modules that work a prescription out. Warmup and
    # SetScheme are handed one of these rather than a bare increment, because a percentage
    # of a top weight has to land somewhere loadable and neither of them can be asked to
    # know what this rack holds. The increment rides along because a ramp still has to know
    # how far apart to space its rungs, which is a question the increment answers correctly.
    def loading(is_barbell: true)
      Rounding::Loading.new(increment:, round: ->(weight) { loadable(weight, is_barbell:) })
    end

    # Every weight this rack can load, worked out once and kept. A week's generation asks
    # for a few dozen roundings and every one of them would otherwise re-enumerate the same
    # rack. Empty for an inventory with no counts on it, which is the case `loadable` falls
    # back to the increment for.
    def loadable_totals
      @loadable_totals ||= Plates.totals(bar_weight:, inventory: pairs) || []
    end

    # The per-side breakdown, or nil when this rack cannot make the weight.
    def per_side(total)
      Plates.per_side(total, bar_weight:, inventory: pairs)
    end

    # The nearest weight this rack can load and what it takes, for a weight `per_side`
    # had to answer nil to. See Plates.closest for why nil is not an answer worth showing.
    def closest(total)
      Plates.closest(total, bar_weight:, inventory: pairs)
    end

    # There was a `label(total)` here, folding per_side straight into Plates.label. It is
    # gone rather than merely unused: what it returned for a weight this rack cannot make
    # was the empty string, which is the silence #111 was about, and leaving a one-line
    # convenience that quietly reintroduces the bug is how the bug comes back. A caller
    # wanting text asks per_side and decides for itself what nil should say.

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
        # Float() rather than Integer(), which refused "33.07" outright and left the bar
        # at whatever it already was without saying so. Stored through the numeric column,
        # so the two decimal places are exact rather than the nearest binary fraction.
        bar = Float(bar_weight.to_s, exception: false)
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

