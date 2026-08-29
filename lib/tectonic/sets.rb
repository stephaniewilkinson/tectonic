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
  end
end

