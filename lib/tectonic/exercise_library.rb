# frozen_string_literal: true

require_relative 'exercises'

class Tectonic < Roda
  class Exercise < Sequel::Model
    # Built-in barbell movements every account can select without any setup. A
    # library row has a nil account_id. Loaded by `rake library:exercises`,
    # which is idempotent on name and safe to run on every deploy.
    LIBRARY = [
      # Competition
      'Back Squat',
      'Bench Press',
      'Deadlift',
      # Squat
      'Front Squat',
      'High-Bar Squat',
      'Low-Bar Squat',
      'Pause Squat',
      'Box Squat',
      'Heel-Elevated Squat',
      'Tempo Squat',
      'Anderson Squat',
      'Safety Bar Squat',
      'Zercher Squat',
      'Overhead Squat',
      # Hinge
      'Sumo Deadlift',
      'Deficit Deadlift',
      'Block Pull',
      'Rack Pull',
      'Paused Deadlift',
      'Romanian Deadlift',
      'Stiff-Leg Deadlift',
      'Snatch-Grip Deadlift',
      'Trap Bar Deadlift',
      'Good Morning',
      'Barbell Hip Thrust',
      'Barbell Glute Bridge',
      # Bench and press
      'Close-Grip Bench Press',
      'Wide-Grip Bench Press',
      'Incline Bench Press',
      'Decline Bench Press',
      'Paused Bench Press',
      'Tempo Bench Press',
      'Spoto Press',
      'Larsen Press',
      'Floor Press',
      'Pin Press',
      'Board Press',
      'Overhead Press',
      'Seated Overhead Press',
      'Push Press',
      'Z Press',
      # Pull
      'Bent Over Row',
      'Pendlay Row',
      'Yates Row',
      'Landmine Row',
      'Barbell Shrug',
      'Barbell Curl',
      'Barbell Skull Crusher',
      # Explosive
      'Power Clean',
      'Hang Clean',
      'Clean Pull',
      'Power Snatch',
      'Snatch Pull',
      'Push Jerk'
    ].freeze

    # The same names folded for comparison, so the lookup below is a matter of
    # spelling rather than of which row an account happens to be holding.
    BARBELL_NAMES = LIBRARY.map(&:downcase).freeze

    # Whether this movement is loaded on a bar, which is what decides if a set of it gets
    # plate math and a warmup ramp. It is a property of the movement, so it is a column on
    # the movement; every write path still asks here rather than each of them remembering
    # to supply a flag, which is what let three of them forget. This used to match the
    # name against the library, which was right for the fifty-four movements the library
    # names and could never be right for anything else -- a lifter's own variation, or a
    # movement an assistant invented, was a barbell lift or not by spelling alone.
    def barbell?
      is_barbell
    end

    # What a movement of this name is, for the paths that create one with nobody to ask:
    # the library loader, the program seed, and the MCP resolver, which turns any name a
    # model has not seen before into a private row. A person creating one in the UI is
    # asked outright and their answer stands, so this is a default rather than a rule.
    def self.barbell_by_name?(name)
      BARBELL_NAMES.include?(name.to_s.strip.downcase)
    end

    # Inserts any missing library rows and returns [created, skipped]. Idempotent
    # on name, so running it again is a no-op. Every library movement is a barbell
    # movement, so a database built by this loader needs no backfill to be right.
    def self.load_library
      missing = LIBRARY.select { |name| where(account_id: nil, name:).empty? }
      missing.each { |name| insert(account_id: nil, name:, is_barbell: true) }
      [missing.length, LIBRARY.length - missing.length]
    end
  end
end

