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

    # The picture beside a movement on the workout record, keyed by the end of its name
    # and paired with what the drawing actually shows. The end of the name is where the
    # movement itself is in every name the library uses -- "Paused Bench Press" is a bench
    # press, "Snatch-Grip Deadlift" is a deadlift -- so four of these lines cover thirty-one
    # of the fifty-four, and they go on being right for a lifter's own "Belted Back Squat",
    # which a list of the library's names could never be. The fifth draws nothing built in:
    # every library movement is loaded on a bar and none of them is a pull-up, so that icon
    # waits for a movement somebody adds. Deciding this by name is what barbell? below
    # stopped doing and for good reason; it is allowed here because being wrong costs a
    # small drawing rather than a plate breakdown, and because icon_url overrides it.
    #
    # The alt text is kept beside the file rather than built from the movement's name,
    # because that is the bug this replaces: one figure holding a dumbbell for every lift,
    # under an alt that said "Plank icon". An alt describing the drawing cannot drift from
    # the drawing.
    ICONS = {
      'squat' => { src: '/icons/squat.svg', alt: 'Squat icon' },
      'deadlift' => { src: '/icons/deadlift.svg', alt: 'Deadlift icon' },
      'bench press' => { src: '/icons/benchpress.svg', alt: 'Bench press icon' },
      'row' => { src: '/icons/row.svg', alt: 'Barbell row icon' },
      'pull-up' => { src: '/icons/pullup.svg', alt: 'Pull-up icon' }
    }.freeze

    # For everything the five do not draw: the presses that are not bench presses, the
    # hinges that are not deadlifts, the olympic lifts, and whatever a lifter invents. A
    # figure holding a barbell is true of all of them, which is more than the figure
    # holding a dumbbell managed in an app that models only the bar.
    GENERIC_ICON = { src: '/icons/gym.svg', alt: 'Barbell icon' }.freeze

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

    # What to draw beside this movement: a src, and the alt that goes with it. An icon_url
    # of the account's own wins. Nothing in the UI sets one any more -- #199 took the field
    # off the form, because #171 gave every movement a shipped icon and so turned the field
    # into a way to override a working default with a fetch from somebody else's server.
    # The MCP tools still write the column, and rows written before that still carry values,
    # so this override is live and is read here. Blank counts as unset: rows added through
    # the old form carry an empty string rather than a null, and an empty src is a broken
    # image on every card.
    #
    # What somebody else's picture shows is not knowable from here, so its alt names the
    # movement it was chosen for and claims nothing about what is in it. A value that could
    # never be an image -- javascript:, data: -- is refused before it is drawn rather than
    # after. The check is here and not on the way in because no write path has ever had
    # one, and one added to them now would still leave every row already stored to be
    # drawn unchecked.
    def icon
      url = icon_url.to_s.strip
      return { src: url, alt: "#{name} icon" } if url.start_with?('/', 'http://', 'https://')

      folded = name.to_s.strip.downcase
      _, drawing = ICONS.find { |movement, _| folded == movement || folded.end_with?(" #{movement}") }
      drawing || GENERIC_ICON
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

