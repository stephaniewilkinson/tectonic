# frozen_string_literal: true

require_relative 'db'
require_relative 'measured'
require_relative 'oauth_application'

class Tectonic < Roda
  # Named WorkoutSet rather than Set because Ruby 4.0 promoted Set to a core class, and a
  # model called Set shadowed it in every file that reopens `class Tectonic` -- which is
  # all of lib/ and app.rb. `Set.new` there returned an empty row of this table rather than
  # a core Set, and did not raise while doing it, so the mistake surfaced somewhere else.
  #
  # The table is named explicitly because Sequel infers one from the class name, and this
  # class is no longer named after its table. The table stays `sets`: it is the right name
  # for what it holds, and it is the class name that had to move.
  class WorkoutSet < Sequel::Model(:sets)
    many_to_one :exercise
    many_to_one :workout
    # The OAuth client (LLM) that created this row, or nil for a human-made one.
    many_to_one :created_by_oauth_application, class: 'Tectonic::OAuthApplication',
                                               key: :created_by_oauth_application_id

    # The measure as a symbol; the column stores text. See Measured for why a dataset
    # filter must still use the string form.
    def measure
      Measured.cast(super)
    end

    def timed?
      measure == Measured::TIME
    end

    # Whether an RPE means anything for this set. #211.
    #
    # RPE is reps in reserve -- an 8 is "two more were there" -- so it needs reps for any
    # to be in reserve of. A 60 second plank has none, and the scale in _rpe_help.erb is
    # written entirely in rep counts ("4+", "3", "2", "1", "0"), so on a timed set it was
    # explaining a measure that could not be applied to it.
    #
    # A warmup is submaximal by definition, so its rating is a number nobody reads back.
    # The session screen already declined to ask for one; this is that rule said once,
    # where the write paths can see it, rather than implied by which list a row is in.
    #
    # Deliberately not is_barbell. That flag decides plate math and a warmup ramp, and a
    # dumbbell press has reps in reserve in exactly the sense a bench press does -- the
    # question is whether the set is counted in reps, not what it is loaded with.
    # Nor unweighted work, which is #278. RPE on a set carrying no external load is a
    # question about a movement rather than about a load: press-ups are as hard as your
    # last set of press-ups made them, and the answer moves nothing the app can act on --
    # there is no weight for Progression to step, and the rating would sit beside a blank
    # where every other rated set has a number. Five 48px buttons is also the tallest thing
    # on a row, and a session of banded and bodyweight accessories was mostly rating scale.
    #
    # This is the screen declining to ask. The database constraint from #211 still permits
    # a rating here, and deliberately: it enforces the two rules that are about meaning --
    # warmups and timed work -- and narrowing it to weight as well would be a migration
    # that clears ratings somebody did record.
    def ratable?
      !is_warmup && !timed? && !weight.nil?
    end

    # The work of one set, doubled where the count was per side. A Bulgarian split squat
    # written 3x8 per side is 48 reps of work, not 24, and counting it as 24 is what made
    # unilateral volume read as half of what was done.
    def counted_reps
      return nil unless reps

      is_per_side ? reps * 2 : reps
    end

    # The two columns that say a set was done, always written together. #281.
    #
    # completed_at is the instant it happened and is_completed is whether it did, and the
    # database refuses a row holding one without the other -- sets_completed_at_needs_a_
    # completion, because a set that was never done carrying the moment it was done is not
    # a state any reader could make sense of.
    #
    # Here rather than at the call sites, and for the same reason ratable? is on the model:
    # four write paths flip is_completed -- the session screen's Done, the set edit form,
    # complete_set and create_set -- and a rule remembered at four places is a rule forgotten
    # at one. The one that would forget it is undo, which is the path that clears the flag,
    # and the failure would be a check violation surfacing as a 500 on a Done button. That
    # is #213's shape, and this is the answer #211 gave to it: enforce it where it cannot be
    # routed around, and give every caller one way to say the thing.
    #
    # An undo clears the stamp rather than keeping it. A set un-completed was not done, so
    # the instant it was done is not a fact any more -- and keeping it would leave a
    # turnaround measured against a set that the lifter has said did not happen.
    #
    # `at` is a parameter with a default rather than a Time.now inside, so a caller with a
    # better answer -- a backdated import, a test pinning a clock -- can give one.
    def self.completion(done, at: Time.now)
      { is_completed: done, completed_at: done ? at : nil }
    end
  end
end

