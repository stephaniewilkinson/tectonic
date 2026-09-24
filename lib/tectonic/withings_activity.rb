# frozen_string_literal: true

require_relative 'db'

class Tectonic < Roda
  # One activity as Withings sent it: what it is called, and the row it becomes. #605.
  #
  # Out of WithingsWorkouts, which is the one answer to "is this recording of this session",
  # because nothing here takes part in that answer. The matcher scores on the interval and on
  # `LIFTING`, and it reads the rows this writes; it does not care what a category is called
  # or how an activity's fields map onto columns. So the seam this cuts is not the one that
  # module's history warns against -- fetching on one side and scoring on the other, which
  # would put one definition of "around this session" in two places. The window, the fetch
  # and the score all stay together over there.
  module WithingsActivity
    module_function

    # What Withings' category integer is called. #568, rebuilt against the primary source
    # by #579.
    #
    # **Data with a source, and this is now Withings' own.** These ids are not guessable and
    # not derivable from anything in this app: they are Withings', published with the
    # `category` field of the workout object in Measure v2 - Getworkouts. #568 transcribed
    # them from two community mirrors, because the reference at developer.withings.com renders
    # client-side and cannot be fetched as text, and said so honestly. That constraint turned
    # out to be a constraint on the *page* rather than on the document: the whole OpenAPI
    # definition is embedded as a string literal in the page's own JavaScript bundle, and the
    # bundle is plain text.
    #
    #   curl -s https://developer.withings.com/assets/js/main.<hash>.js
    #
    # where the hash comes from the `<script src=...>` of `/api-reference/`; it was
    # `main.8ae1c0ad.js` on 2026-09-23, and the table greps out of it as a markdown table
    # under `workout_object`. That is how every name below was read, and it is how the next
    # person should re-read them when Withings adds more -- they add several a year, and the
    # bundle hash changes on every deploy of their site, so the hash is looked up rather than
    # remembered.
    #
    # **What that cost us, written down because it is the argument for going to the source.**
    # The mirrors had 17 as "Calisthenics" and Withings has it as "Fitness" -- and 042's own
    # comment said "Fitness" all along, so the repo has been contradicting itself in two files
    # since the table landed. They swapped 193 and 194, which is why #568 left both out; they
    # are Hockey and Ice hockey, in that order. They carried 186 as "Base", and Withings
    # publishes no 186 at all, so the one id #568 suspected of being a mirror's invention was
    # exactly that. And they were missing 36 "Other", 128 "No activity" and 306 "Indoor walk"
    # -- 306 being the id `called`'s own comment reasons about as unnameable, which it has
    # never been.
    #
    # The spellings are ours where Withings' are wrong, which is the rule #568 set and the
    # reason it set it: this string is shown on a page, and a provider's typo reads as the
    # app's. Withings write "Seated Strenght" and "Breathing excercises", and both are
    # corrected here; "Basket-ball", "Volley-ball" and "Waterpolo" keep the spellings this
    # table already had. **Their capitalisation is left exactly as they write it**, mixed as
    # it is -- "Table tennis" beside "Trail Running" -- because a case style is not a
    # misspelling, and the lifter is being asked to recognise the watch's own word for their
    # afternoon rather than this app's restyling of it.
    #
    # The gaps in the numbering are Withings' too. There is no 37 through 127, no 533, and a
    # good deal else besides; ids are allocated as activities are added and retired ones are
    # not reused. Anything absent falls through to `called`, which prints the number and
    # claims nothing, and that fallback is not going away because this table is fuller -- the
    # next activity Withings adds will land in it the day it ships and before anybody here
    # has re-read the bundle.
    #
    # **It decides nothing.** Nothing scores off this, nothing filters on it, and no reader of
    # it may ask whether a category counts as lifting -- that is `WithingsWorkouts::LIFTING`, and one
    # question with two tables to answer it from is how the two come to disagree.
    CATEGORIES = {
      1 => 'Walk', 2 => 'Run', 3 => 'Hiking', 4 => 'Skating', 5 => 'BMX', 6 => 'Bicycling',
      7 => 'Swimming', 8 => 'Surfing', 9 => 'Kitesurfing', 10 => 'Windsurfing', 11 => 'Bodyboard',
      12 => 'Tennis', 13 => 'Table tennis', 14 => 'Squash', 15 => 'Badminton', 16 => 'Lift weights',
      17 => 'Fitness', 18 => 'Elliptical', 19 => 'Pilates', 20 => 'Basketball', 21 => 'Soccer',
      22 => 'Football', 23 => 'Rugby', 24 => 'Volleyball', 25 => 'Water polo', 26 => 'Horse riding',
      27 => 'Golf', 28 => 'Yoga', 29 => 'Dancing', 30 => 'Boxing', 31 => 'Fencing',
      32 => 'Wrestling', 33 => 'Martial arts', 34 => 'Skiing', 35 => 'Snowboarding', 36 => 'Other',
      128 => 'No activity', 187 => 'Rowing', 188 => 'Zumba', 191 => 'Baseball', 192 => 'Handball',
      193 => 'Hockey', 194 => 'Ice hockey', 195 => 'Climbing', 196 => 'Ice skating',
      272 => 'Multi-sport', 306 => 'Indoor walk', 307 => 'Indoor running', 308 => 'Indoor cycling',
      455 => 'Standup Paddleboarding', 456 => 'Padel', 457 => 'Gaming', 490 => 'Beach volleyball',
      491 => 'Stair Stepper', 492 => 'Skateboarding', 493 => 'Parkour', 494 => 'Kayaking',
      495 => 'Canoeing', 496 => 'Sailing', 497 => 'Fishing', 498 => 'Trail Running',
      499 => 'Snowshoeing', 500 => 'Paintball', 501 => 'Archery', 502 => 'Scuba Diving',
      503 => 'Baseball Training', 504 => 'Biathlon', 505 => 'Bocce', 506 => 'Pétanque',
      507 => 'Paragliding', 508 => 'Frisbee', 509 => 'Skydiving', 510 => 'Pickleball',
      511 => 'Cornhole', 512 => 'Dodgeball', 513 => 'Ultimate', 514 => 'Teqball',
      515 => 'Pushing a Wheelchair (Running Pace)', 516 => 'Pushing a Wheelchair (Walking Pace)',
      517 => 'Athletics', 518 => 'Track Cycling', 519 => 'Pentathlon', 520 => 'Sport Shooting',
      521 => 'Triathlon', 522 => 'Diving', 523 => 'Mountain Biking', 524 => 'Gravel Biking',
      525 => 'E-Biking', 526 => 'E-Mountain Biking', 527 => 'Handcycling', 528 => 'Velomobile',
      529 => 'Backcountry Skiing', 530 => 'Nordic Skiing', 531 => 'Roller Skiing',
      532 => 'Racquetball', 534 => 'Hip Hop', 535 => 'Muaythai', 536 => 'Taekwondo', 537 => 'Judo',
      538 => 'Trampoline', 539 => 'Standing Frame', 540 => 'Seated Strength',
      541 => 'Seated Cardio', 542 => 'Walk With Walker', 543 => 'Walk With Cane', 544 => 'Breaking',
      545 => 'Chores', 546 => 'Crossfit', 547 => 'Spinclass', 548 => 'Cricket',
      549 => 'Flamenco Dancing', 550 => 'HIIT', 551 => 'Meditation', 552 => 'Stretching',
      553 => 'Yard Work Gardening', 554 => 'Cleaning', 555 => 'Public Speaking', 556 => 'Spikeball',
      557 => 'Lacrosse', 558 => 'Baby Wearing', 559 => 'Dog Walking', 560 => 'Breathing exercises',
      561 => 'Balance Drills', 562 => 'Pushing a Stroller', 563 => 'Toddler Wearing',
      564 => 'Bowling', 565 => 'Lasertag', 566 => 'Nordic Walking', 567 => 'Sumo Wrestling',
      568 => 'Cooking', 569 => 'Match Day'
    }.freeze

    # What to call an activity where a lifter has to recognise it. Withings' name for the
    # category where they publish one; the id itself where they do not.
    #
    # **The fallback invents nothing**, which is the point of having one. The reporting
    # account's second activity is category 6, and before #568 the app could not name it at
    # all; the temptation at that discovery is to write "Activity" or "Other" over every id the
    # table is missing, which reads as a name and is not one -- a lifter would take "Other" for
    # something they had tapped in Health Mate. "Withings category 533" is plainly the app
    # saying it does not know, and it carries the one thing that makes the gap fixable: the
    # number to look up.
    #
    # **This used to reason about 306, and 306 is "Indoor walk".** That was the cost of
    # transcribing the table from mirrors: the worked example of an id nobody could name was
    # an id Withings publishes a name for, and had all along. #579 rebuilt `CATEGORIES` from
    # Withings' own document, so the example here is 533 instead -- a number inside the
    # published range that the published table skips. The fallback itself is unchanged and is
    # not going to become unnecessary: Withings add categories faster than anyone here will
    # re-read their bundle. And one of the ids the rebuild brought in is 36, "Other" -- a real
    # tag a lifter can actually tap, which is precisely why this may never write that word over
    # a number it does not recognise.
    def called(category)
      return 'An activity Withings did not name' unless category

      CATEGORIES[category] || "Withings category #{category}"
    end

    # One activity, written so that writing it twice is writing it once.
    #
    # The same idempotency pattern as `WithingsConnection.store` and the unique index in 041:
    # a unique target and `insert_conflict`, so a window re-read on the next page view is a
    # no-op rather than a second copy of a fortnight.
    #
    # **`workout_id` and `dismissed_at` are absent from the update on purpose.** They are the
    # lifter's answer, and a re-fetch is not new information about it. Withings will keep
    # sending an activity that has been confirmed or refused -- it is still in their account
    # -- and an upsert that wrote every column would un-answer the question every time the
    # page was opened, which is precisely the nagging #520 forbids.
    def store(account_id, activity)
      row = columns(activity)
      DB[:withings_workouts].insert_conflict(target: %i[account_id external_id], update: row)
                            .insert(account_id:, external_id: activity['id'].to_s, **row)
    end

    # Everything Withings sent about one activity, in this schema's names.
    def columns(activity)
      { started_at: Time.at(activity['startdate'].to_i),
        ended_at: Time.at(activity['enddate'].to_i), timezone: activity['timezone'],
        modified_at: stamp(activity['modified']),
        **labels(activity), **fields(activity['data']) }
    end

    # The three integers on the activity itself, as against the measurements under `data`.
    #
    # The distinction is the whole reason these are grouped: `data` arrives only because
    # `WORKOUT_FIELDS` named each of its members, and these arrive whether anybody asked or
    # not. They cost no parameter, no extra request and no scope.
    #
    # **`model` is one of them and was being thrown away**, which #579 is the accounting for.
    # Until 050 there was nowhere to put it, so the one fact saying which instrument recorded
    # a session was discarded on every fetch this app has ever made -- and the reporting
    # account has been connected for months with nobody here able to say which watch it wears.
    # That matters beyond curiosity: #579's whole list of candidate metrics runs into fields
    # that come back absent when the plan or the device does not entitle us to them, which is
    # indistinguishable from a device that recorded nothing, and the device is the only thing
    # that tells those two apart.
    #
    # `&.to_i` on all three rather than `.to_i`, because `nil.to_i` is 0 and 0 is a category
    # nobody tapped and a model nobody owns. An activity typed into the Withings app by hand
    # has no instrument to name, and null is what that is.
    def labels(activity)
      { category: activity['category']&.to_i, attrib: activity['attrib']&.to_i,
        model: activity['model']&.to_i }
    end

    def stamp(epoch) = epoch.nil? ? nil : Time.at(epoch.to_i)

    # The measurements, which arrive under `data` and only because they were asked for by
    # name. Nil rather than zero where one is absent: a watch that recorded no heart rate and
    # a watch that recorded a resting one are different, and a zero would read as the second.
    #
    # `effective_seconds` is no longer among them. #586: `effduration` is not a Withings field --
    # it appears nowhere in the OpenAPI document behind their reference, and 042 added a column
    # for it on the strength of a name in `WORKOUT_FIELDS` that nothing had ever checked.
    # `Withings::WORKOUT_FIELDS` carries the accounting, and 053 dropped the column (#607).
    # Taking the key out of here rather than leaving it reading a key that can never arrive
    # was the point: a lookup that is always nil is indistinguishable from a measurement this
    # watch happens not to take, and that ambiguity is the one thing this integration has
    # spent the most effort removing.
    def fields(data)
      data = {} unless data.is_a?(Hash)
      { calories: data['calories'], hr_average: data['hr_average']&.to_i,
        hr_min: data['hr_min']&.to_i, hr_max: data['hr_max']&.to_i }
    end
  end
end

