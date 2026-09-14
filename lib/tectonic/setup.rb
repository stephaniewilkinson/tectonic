# frozen_string_literal: true

class Tectonic < Roda
  # How the room is set up for a lift, in words. #412.
  #
  # Chest-Supported DB Row was programmed with the note "incline bench" and nothing more. The
  # lifter set 30 degrees, correctly, and had no way to know that was what was intended.
  #
  # 034 put the three numbers on the prescription and on the rows it writes. This is the one
  # place they become a phrase, so the session screen, the record and an assistant reading a
  # session back all say the same thing about the same set -- which is the mismatch #306 and
  # #320 were both about, arriving a third time.
  #
  # ## Why a phrase and not three fields on the screen
  #
  # A set row on a phone is read at arm's length with chalk on. "bench 30°, J-hooks 11,
  # safeties 7" is one line a lifter scans; three labelled fields is a form. The numbers stay
  # numbers in the payload, where a reader that wants to compute with them can, and this is
  # only how they are said.
  #
  # ## Silence is the common case
  #
  # Almost every set has no setup at all, and a row that said "bench —" on every barbell curl
  # would be worse than the note it replaces. Nil rather than an empty string, so a caller has
  # to decide what to do about nothing rather than printing it by accident.
  module Setup
    # The degree sign, once. A bench angle is the one number here with a unit, and the unit is
    # the thing that makes "30" read as an angle rather than as a weight.
    DEGREES = '°'

    module_function

    # The setup as one phrase, or nil where nothing was prescribed.
    #
    # Ordered as a lifter does it: the bench before the bar, because you set the bench up and
    # then get under the weight, and the safeties last because they are the thing you set and
    # forget. Not alphabetical, which would put the bench between the hooks and the safeties
    # and split the two rack numbers that are read together.
    def phrase(row)
      parts = [bench(row), hooks(row), safeties(row)].compact
      parts.empty? ? nil : parts.join(', ')
    end

    # Zero is flat and is a real instruction, which is why this tests for nil rather than for
    # truthiness -- zero is truthy in Ruby, so that much is safe, but the column is nullable
    # precisely so that "flat" and "nobody said" stay different answers and a reader here has
    # to keep them different too.
    #
    # A negative angle is a decline bench and says so in words rather than as a minus sign: on
    # a row that also holds weights and rep counts, "-15°" is a number somebody has to work out
    # is not a subtraction.
    def bench(row)
      degrees = row[:bench_angle_degrees]
      return nil if degrees.nil?
      return 'flat bench' if degrees.zero?
      return "bench #{degrees.abs}#{DEGREES} decline" if degrees.negative?

      "bench #{degrees}#{DEGREES}"
    end

    # "J-hooks" rather than "rack", because a rack has two sets of numbered holes and naming
    # one of them "rack" would leave the other needing a name that distinguishes it anyway.
    def hooks(row)
      row[:rack_hole] && "J-hooks #{row[:rack_hole]}"
    end

    def safeties(row)
      row[:safety_hole] && "safeties #{row[:safety_hole]}"
    end

    # The three columns as they travel: from a prescription onto the rows the generator writes,
    # and from one tool's arguments to another's. Named once so a caller cannot copy two of
    # three and leave a session set up half right, which is the failure mode a hand-written
    # list of columns has -- and which #289 and the MCP copy-a-week bug both were.
    COLUMNS = %i[bench_angle_degrees rack_hole safety_hole].freeze

    # What a row says about its own setup, for copying onto another.
    def of(row) = COLUMNS.to_h { |column| [column, row[column]] }
  end
end

