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

    # The work of one set, doubled where the count was per side. A Bulgarian split squat
    # written 3x8 per side is 48 reps of work, not 24, and counting it as 24 is what made
    # unilateral volume read as half of what was done.
    def counted_reps
      return nil unless reps

      is_per_side ? reps * 2 : reps
    end
  end
end

