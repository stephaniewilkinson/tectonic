# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  class ProgramLift < Sequel::Model
    many_to_one :program_day
    many_to_one :exercise

    # Counted in seconds rather than in reps: a plank, a carry, a walk. The measure
    # decides which quantity column carries the number, so every reader asks here rather
    # than guessing from which column happens to be null.
    def timed?
      measure == 'time'
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

