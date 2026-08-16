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

    # Inserts any missing library rows and returns [created, skipped]. Idempotent
    # on name, so running it again is a no-op.
    def self.load_library
      missing = LIBRARY.select { |name| where(account_id: nil, name:).empty? }
      missing.each { |name| insert(account_id: nil, name:) }
      [missing.length, LIBRARY.length - missing.length]
    end
  end
end

