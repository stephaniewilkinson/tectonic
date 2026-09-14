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

    attr_reader :bar_weight, :pairs, :dumbbell_handle_weight, :dumbbell_pairs

    # `pairs` maps a denomination to how many pairs of it the account owns.
    #
    # The two dumbbell arguments are #369's second rack and default to nothing, which is what
    # every account had before that issue and still has until somebody fills the form in.
    # Nothing rather than a default pair of values, because a default would be a claim that
    # every account owns adjustable dumbbells -- and the honest description of a fixed rack is
    # the constant below, not an invented inventory.
    def initialize(bar_weight:, pairs:, dumbbell_handle_weight: nil, dumbbell_pairs: {})
      @bar_weight = bar_weight
      @pairs = pairs
      @dumbbell_handle_weight = dumbbell_handle_weight
      @dumbbell_pairs = dumbbell_pairs
    end

    def self.for_account(account_id)
      account = DB[:accounts].where(id: account_id).first || {}
      new(bar_weight: account[:bar_weight] || DEFAULT_BAR,
          pairs: barbell_pairs(account_id),
          dumbbell_handle_weight: numeric(account[:dumbbell_handle_weight]),
          dumbbell_pairs: numeric_keys(DB[:account_dumbbell_plates].where(account_id:)
                                         .to_hash(:denomination, :pairs)))
    end

    # An account that has never said what it owns lifts on the default rack. The dumbbell
    # inventory has no equivalent and must not gain one: an empty barbell rack is somebody who
    # has not answered, and an empty dumbbell rack is somebody saying they have a fixed one.
    def self.barbell_pairs(account_id)
      owned = DB[:account_plates].where(account_id:).to_hash(:denomination, :pairs)
      owned.empty? ? DEFAULT_PLATES : numeric_keys(owned)
    end

    def self.numeric(value)
      value && Plates.numeric(value.to_r)
    end

    # The nearest weight one account's rack can build, which is where a prescription should
    # land (#259). Here rather than on the program writer because it is a question about a
    # rack, and because three write paths ask it -- a lift inside a new block, a lift added
    # to a day, and an edit to one. Rounding on two of those and not the third is the shape
    # of the bug rather than a fix for it.
    def self.loadable_for(account_id, weight, is_barbell:)
      return weight if weight.nil?

      for_account(account_id).loadable(weight.to_f, is_barbell:)
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

    # The smallest step a dumbbell makes, which is not the smallest step this bar makes.
    # A fixed dumbbell rack runs 5, 10, 15 and up in fives, and no plate an account owns
    # for its barbell changes that: buying a pair of 1 lb plates takes `increment` to 2 and
    # would otherwise start prescribing 26 and 28 lb dumbbells, which almost nobody has.
    #
    # An assumption rather than an inventory, and worth naming as one (#259). The app knows
    # what plates an account owns and nothing at all about its dumbbells, so this is the
    # common case stated plainly: fives, unless the bar itself cannot manage fives, in which
    # case the coarser number is the honest one. An account with adjustable dumbbells that
    # micro-load is not served by this, and is not served by anything else here either --
    # that wants a second inventory, which is a bigger thing than a rounding rule.
    DUMBBELL_INCREMENT = 5

    # Whether this account has described a second rack. #369.
    #
    # Both halves, because neither is any use alone: a handle weight with no plates loads
    # nothing, and plates with no handle have nothing to go on. An account that has filled in
    # one and not the other is describing a rack that does not exist, and the honest reading of
    # it is the fixed rack everybody else has.
    def adjustable_dumbbells?
      !dumbbell_handle_weight.nil? && dumbbell_handle_weight.positive? && !dumbbell_pairs.empty?
    end

    # The smallest step the dumbbells make, from their own plates rather than from the bar's.
    # #369: a pair of Powerblocks steps in 2.5 at the bottom, and the barbell's micro plates
    # have nothing to do with it.
    def dumbbell_increment
      return DUMBBELL_INCREMENT unless adjustable_dumbbells?

      Plates.numeric(dumbbell_pairs.keys.min.to_r * 2)
    end

    # Every weight the dumbbells can load, worked out once and kept.
    #
    # `Plates.totals` without knowing which rack it is looking at, which is the whole reason
    # 033 gave the second inventory 007's shape: a dumbbell is loaded at both ends the way a
    # bar is loaded at both sides, so the handle stands where the bar does and a pair of plates
    # means the same thing on either.
    def dumbbell_totals
      return [] unless adjustable_dumbbells?

      @dumbbell_totals ||= Plates.totals(bar_weight: dumbbell_handle_weight, inventory: dumbbell_pairs) || []
    end

    # How far apart two loads of this kind sit. The bar answers from its plates, and since
    # #369 so do the dumbbells -- from their own.
    def increment_for(is_barbell:)
      return increment if is_barbell

      dumbbell_increment
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
    # Anything not on the bar rounds to its own increment rather than to the bar's, which
    # is #259's dumbbell half: a rack that gains a pair of 1 lb plates takes `increment` to
    # 2, and 26 lb dumbbells are not a thing most gyms have.
    # Since #369 the dumbbell branch enumerates too, where the account has said what its
    # dumbbells are. It is the same question -- what can this rack build -- and the same
    # argument against divisibility applies: a handle with 5s and 10s on the shelf cannot make
    # 22.5, and an increment of 5 says it can.
    #
    # An account that has said nothing keeps exactly the rounding it had, against the constant
    # #259 named as an assumption, because a fixed rack really does run in fives.
    def loadable(weight, is_barbell: true)
      return weight if weight.nil?
      return nearest(weight, dumbbell_totals, dumbbell_increment) unless is_barbell

      nearest(weight, loadable_totals, increment)
    end

    # The nearest of an enumerated set, or the nearest multiple where there is nothing
    # enumerated to choose from.
    #
    # A tie goes to the lighter weight, following Plates.closest: overshooting a prescription
    # adds work nobody asked for and can turn a planned single into a miss, where undershooting
    # by the same amount costs a little stimulus and nothing else.
    def nearest(weight, totals, step)
      return Rounding.to_increment(weight, increment: step) if totals.empty?

      totals.min_by { |total| [(total - weight).abs, total] }
    end

    # How this rack loads, for the modules that work a prescription out. Warmup and
    # SetScheme are handed one of these rather than a bare increment, because a percentage
    # of a top weight has to land somewhere loadable and neither of them can be asked to
    # know what this rack holds. The increment rides along because a ramp still has to know
    # how far apart to space its rungs, which is a question the increment answers correctly.
    def loading(is_barbell: true)
      Rounding::Loading.new(increment: increment_for(is_barbell:),
                            round: ->(weight) { loadable(weight, is_barbell:) })
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
    def self.replace(account_id, bar_weight:, plates:, dumbbell_handle_weight: nil, dumbbell_plates: nil)
      DB.transaction do
        # Float() rather than Integer(), which refused "33.07" outright and left the bar
        # at whatever it already was without saying so. Stored through the numeric column,
        # so the two decimal places are exact rather than the nearest binary fraction.
        bar = Float(bar_weight.to_s, exception: false)
        DB[:accounts].where(id: account_id).update(bar_weight: bar) if bar&.positive?
        write_plates(:account_plates, account_id, plates)
        write_handle(account_id, dumbbell_handle_weight)
        write_plates(:account_dumbbell_plates, account_id, dumbbell_plates)
      end
    end

    # One rack's plates, replaced wholesale. Both inventories are written this way for the
    # reason the barbell one always was: the rack is one fact, and a partial update would
    # leave the increment reading off plates the lifter had just removed.
    def self.write_plates(table, account_id, plates)
      return if plates.nil?

      DB[table].where(account_id:).delete
      owned(plates).each { |denomination, count| DB[table].insert(account_id:, denomination:, pairs: count) }
    end

    # A blank handle is a real answer and means "a fixed rack", which is what every account had
    # before #369 -- so it is written as null rather than ignored. That is the one way back from
    # having described adjustable dumbbells, and without it the answer would be unsayable once
    # it had been said.
    def self.write_handle(account_id, weight)
      return if weight.nil?

      given = Float(weight.to_s, exception: false)
      DB[:accounts].where(id: account_id).update(dumbbell_handle_weight: given&.positive? ? given : nil)
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

