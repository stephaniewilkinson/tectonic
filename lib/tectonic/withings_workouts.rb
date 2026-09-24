# frozen_string_literal: true

require_relative 'db'
require_relative 'timing'
require_relative 'withings'
require_relative 'withings_connection'

class Tectonic < Roda
  # The activity a watch recorded, and whether it was this session. #520.
  #
  # ## Propose and confirm, and nothing else
  #
  # #520 settled the flow in one line: *"close your workout in Withings, tap finish workout
  # in Tectonic, and Tectonic asks to match the records."* So this proposes and the lifter
  # answers. It never matches silently, which is the thing the issue is most explicit about
  # -- a lifter who walked the dog at 18:00 and lifted at 18:30 has two activities, and the
  # watch may well have called either one strength training. **An overlap in time is good
  # evidence and not proof**, and the difference between evidence and proof is a tap.
  #
  # And it never writes to Withings. The app reads; the watch is the instrument.
  #
  # ## What an interval is, here
  #
  # `workouts.date` is a timestamp that only ever holds midnight -- every writer puts a date
  # in it and every reader casts it back -- so it says nothing at all about when a session
  # ran and is useless for this. The real clock is on `sets.completed_at`, and Timing already
  # reduces it to the two ends: `started_at` is the first completion, `ended_at` is
  # `finished_at` where the lifter said they were done and the last completion otherwise.
  # This reuses `Timing.session` rather than asking the database the same question again, on
  # the grounds that two expressions of "when did this session run" would eventually
  # disagree, and the one that disagreed would be this one.
  #
  # ## The timezone assumption, written down rather than hidden
  #
  # `sets.completed_at` is `timestamp without time zone`, and so are the two ends stored
  # here. Neither carries a zone, so comparing them is only meaningful if both were written
  # in the same one -- and they are: this process writes both, `Time.now` for a completion
  # and `Time.at(epoch)` for a Withings activity, and Sequel is left at its default of
  # storing a Time's local reading. So the comparison holds on any machine, *provided the
  # machine's zone does not change between writing a set and fetching an activity.*
  #
  # On Render the zone is UTC and the question does not arise. On a laptop it does not arise
  # either, until somebody travels. What would break it is a deployment moved between zones
  # with sessions already stored, which would shift every old stamp against every new one --
  # and that is #349's problem rather than this one's. It is worth knowing that the app
  # already makes the stronger version of this assumption elsewhere: `_clock_time.erb`
  # prints `at.utc` and calls it UTC.
  #
  # ## Sessions that cannot match, which is not a bug
  #
  # A session logged at ten at night for training done at seven carries ten o'clock, because
  # `completed_at` is when the tap happened. Nothing overlaps it, no proposal appears, and
  # that is the correct answer rather than something to paper over: the app does not know
  # when that session was trained, and guessing would produce exactly the silent mismatch
  # #520 refuses.
  module WithingsWorkouts
    # Which of Withings' categories look like a barbell session: 16, "Lift weights", and 17,
    # "Fitness" -- the two a barbell session plausibly gets tagged as.
    #
    # **17 is here whatever it is called**, and #579 established that it is called "Fitness"
    # rather than "Calisthenics" -- see `CATEGORIES`. Naming a category and deciding whether it
    # looks like lifting are separate questions on purpose, and the correction to the first
    # does not touch the second: a watch that tags a barbell session as 17 tags it as 17, and
    # what the tag is *called* is a string shown to a lifter rather than a term of the sum.
    # This list moved not one id when the names were rebuilt from the primary source, which is
    # the whole return on keeping the two apart.
    #
    # **Scoring only.** Nothing filters on this. A lifter who tapped "Other", or whose watch
    # guessed, still lifted, and a category test that excluded them would turn a confident
    # guess into a missing feature.
    #
    # **Ids and no names since #568**, which is the one change here and the point of it. This
    # used to be a hash carrying both the decision and the two names, and #568 needs a name for
    # every category Withings has rather than for these two -- so the names moved to
    # `CATEGORIES` and this kept the decision. Had the table been added beside this one with
    # its own copies of 16 and 17, there would be two answers to "what is 17 called" and,
    # sooner or later, two answers to "does 17 count as lifting", which is the question
    # `CATEGORY_BONUS` is the whole weight of.
    LIFTING = [16, 17].freeze
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
    # it may ask whether a category counts as lifting -- that is `LIFTING` above, and one
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
    # How many of the activities around a session the box names one by one. #568.
    #
    # Three, because the box is read on a phone under the session it is about, and the realistic
    # case is two or three -- a walk and a ride, or a lift the watch split in two. A lifter
    # whose watch recorded ten things that day is not served by ten lines pushing the controls
    # off the screen; they are served by the three nearest the session and a count of the rest,
    # which is enough to tell whether their lift is in there and enough to say the box is not
    # hiding anything.
    #
    # Nearest by start rather than earliest in the window, which is the same measure `best`
    # breaks its ties with and for the same reason: an activity's distance from the first set
    # is what makes it a plausible recording of this session, so a cap that kept the earliest
    # three would drop the one from ten minutes afterwards -- the one most likely to be the
    # lift, filed against the wrong clock -- in favour of three from the previous morning.
    NAMED = 3
    # How much being tagged as lifting is worth, expressed in the same units as the overlap
    # ratio so the two can simply be added.
    #
    # A quarter, which is deliberately not enough to win on its own: an activity tagged "Lift
    # weights" overlapping a tenth of the session loses to an untagged one overlapping all of
    # it, and it should, because the overlap is measured and the tag is a label somebody
    # tapped. It is enough to break the realistic tie, which is a walk and a lift that both
    # touch the session window.
    CATEGORY_BONUS = 0.25
    # How far either side of the session to ask Withings for, in civil days.
    #
    # `getworkouts` takes dates rather than instants, so a session at 23:40 needs tomorrow
    # asked for as well -- and one at 00:20 needs yesterday. A day each way covers both and
    # costs one request either way.
    MARGIN_DAYS = 1
    # How long after a session ends the app is still willing to say an upload may be coming.
    #
    # **This was `LOOKS_BACK`, and it bounded something else entirely.** It was how long the
    # record page kept *asking Withings* about a session, and the argument for having a bound
    # at all was rate limiting: `proposal` fetched on every view inside the window, so without
    # one, browsing a year of training was a few hundred API calls -- which is how a read-only
    # integration gets itself throttled, and a throttled fetch is the one failure this page
    # cannot render honestly (see `Withings.workouts`).
    #
    # **That argument is gone, because #560 removed its cause rather than its symptom.** A
    # page view now reads stored rows and calls nobody; a lifter who wants Withings asked
    # presses a control that asks it. Browsing a year of training is a year of indexed queries
    # and no requests whatever, so there is nothing left for a 24-hour bound to protect -- and
    # proposing from stored activities now applies to a session of any age. That widening is
    # not hypothetical: on the reporting account an activity from yesterday, overlapping a
    # session for 43 of its 49 minutes, sat unproposed purely because the session had passed a
    # day old. It is offered now, on the next page view, with no fetch and no backfill.
    #
    # What the number still governs is a *sentence*. "Nothing from Withings yet" is a claim
    # about lateness, and lateness has a shelf life: closing a workout in the Withings app
    # starts an upload that lands on their servers seconds to minutes later, so for a session
    # that has just finished the claim is true and the advice is worth giving. For a session
    # from last March there is no upload on its way, absent really is absent, and the honest
    # rendering is silence rather than a hedge borrowed from a case that does not apply --
    # which is the distinction `standing` used to keep and this constant now keeps alone.
    #
    # A day rather than an hour, unchanged and for the unchanged reason: a lifter who taps
    # finish and reads the record the next morning is ordinary, and the prompt should be
    # there when they do.
    STILL_ARRIVING = 24 * 60 * 60

    module_function

    # What the record page should say about Withings, or nil where it should say nothing.
    #
    # **It calls nobody.** That is the whole of #560 and it replaces the reasoning that used
    # to sit here, which was #520's: *"the page looks again each time it is opened"*, because
    # the watch's upload is seconds to minutes behind a lifter tapping finish. The observation
    # was right and the implementation put somebody else's service, with a ten-second timeout,
    # in front of an ordinary page render -- so the slowest thing on a record page was
    # Withings, and the number of requests the app made was however many times a session got
    # looked at. Lateness is now handled by a control the lifter presses (see `check`), and
    # what this does is read rows already stored, with one indexed query and no network.
    #
    # Four answers, and they are four rather than two because the differences between them
    # are the substance of #520 and #560:
    #
    #   :matched   -- the lifter said yes, so what only the watch knows can be shown
    #   :proposed  -- a stored activity overlaps, with a sentence saying how much
    #   :waiting   -- nothing of Withings' is stored around this session, and it is recent
    #                 enough that an upload may still be on its way
    #   :elsewhere -- activities *are* stored around this session and none of them overlaps
    #                 it, so something was recorded and it was not this
    #
    # `:matched` used to be described here as *"the watch's numbers are the session's
    # numbers"*, which was #520's rule and is no longer true of the page. #571 reversed it on
    # the reporting account's own data -- a watch that starts late and runs long, calling a 46
    # minute session an hour -- so the session's length and its two ends are the lifter's taps
    # whether or not a match exists, and a match contributes the heart rate, the calories and
    # its own recording's span, all of it labelled as the watch's. Nothing about *matching*
    # changed: this still gates on overlap, still scores on it, and still hands the judgement
    # to the lifter. What changed is what a yes is allowed to do to the figures afterwards.
    #
    # The last two were one state, `:waiting`, and folding them was the bug #560 reports: the
    # page told a lifter whose watch had recorded two activities that morning that nothing had
    # arrived, and advised them to check back in a minute for a thing that had already come
    # and was not theirs. Telling them apart costs one query, which `nearby` makes.
    #
    # `:elsewhere` carries what was recorded rather than how much of it, which is #568: the
    # rows `nearby` already selected, capped at `NAMED` and paired with the session's own two
    # ends so the box can show the mismatch instead of asserting it. See `elsewhere`.
    #
    # `:unreachable` used to be here too and is no longer a state of the page, because the
    # page no longer asks: a request that was never answered is an outcome of a press and is
    # reported as one. The trap it guarded is not gone and has moved to `check` -- Withings
    # signals a rate limit as body status 601 over HTTP 200, so `Withings.answered` folds a
    # throttle into the same nil as a revoked token, and a page that rendered that as "no
    # activity" would be lying about a thing that exists.
    def proposal(account_id:, workout:, timing:)
      found = matched(workout[:id])
      return { state: :matched, activity: found } if found
      return nil if workout[:withings_dismissed_at] || !WithingsConnection.connected?(account_id)

      window = interval(timing)
      window && propose(account_id, window, workout[:id])
    end

    # Is there already an unanswered proposal against this session, and what does it say.
    #
    # **This is the backfill's question now, and only the backfill's.** It used to be the
    # record page's other path: a session older than the window the page would fetch for got
    # whatever the backfill had written down, and a newer one got a live overlap computed by
    # `candidates`. Two paths to one answer, and they did not agree -- `standing` took the
    # first row it found while `candidates` and `best` scored them, so a session with a
    # written proposal and a second overlapping activity could be offered one activity on the
    # record and the other on /workouts/withings, depending only on its age.
    #
    # #560 collapsed that. A page view reads stored rows whatever the session's age, so
    # `candidates` covers every session `standing` used to cover -- every row this can return
    # overlaps the window, because the backfill only ever proposes rows `candidates` handed
    # it -- and `propose` prefers a written proposal outright, so the record page and the
    # review list name the same activity. What is left here is the idempotency check
    # `WithingsBackfill.offer` makes before it writes: one query and one spelling of "is there
    # an unanswered proposal on this session", because two spellings would eventually disagree
    # about whether a dismissed proposal counts, and the disagreement would show up as a
    # session offered a second activity while the first was still on screen.
    def standing(account_id, workout_id, window)
      row = DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id,
                                         workout_id: nil, dismissed_at: nil).first
      row && offered(row, window)
    end

    # The activity a session has already been matched to, or nil. Read on every record page,
    # including the ones this module otherwise has nothing to say about, because a match once
    # made is a fact about the session forever rather than a proposal with a shelf life.
    def matched(workout_id) = DB[:withings_workouts].where(workout_id:).first

    # The two ends of the session, from the reading Timing has already done. Nil where there
    # is nothing to compare: a session with no completed sets has no interval, and a session
    # whose two ends are the same instant has one of zero width, which overlaps nothing and
    # would divide by zero if it tried.
    def interval(timing)
      started_at = timing[:started_at]
      ended_at = timing[:ended_at]
      return nil unless started_at && ended_at && ended_at > started_at

      [started_at, ended_at]
    end

    def still_arriving?(ended_at) = Time.now - ended_at < STILL_ARRIVING

    # Asking Withings about one session, because the lifter asked. #560.
    #
    # **The only thing on a record page that makes a request.** #560 was opened because the
    # box said "check back in a minute" and offered no way to check -- the re-fetch existed,
    # on every page view, and was completely undiscoverable, so the likeliest answer to a
    # prompt meaning "try again shortly" was the button that silences it for good. Moving the
    # fetch behind a press makes it discoverable and, in the same move, takes it off the
    # thirty other page views that never wanted it.
    #
    # Three outcomes, because a lifter who has deliberately pressed a button is owed an
    # answer about what came back rather than a silently identical page:
    #
    #   :answered       -- Withings replied, and whatever it sent is now stored
    #   :unreachable    -- Withings did not reply, so nothing has been learned either way
    #   :nothing_to_ask -- no interval or no connection, so there was no question to put
    #
    # `:unreachable` is the trap #520 wrote `:unreachable` into the page for, in its proper
    # place: Withings delivers a rate limit as body status 601 over HTTP 200, exactly like a
    # revoked token and every other error they have, and `Withings.answered` folds the lot
    # into nil. A press that was throttled and a press that found nothing are the same shape
    # by the time they reach here, and they are told apart by that nil and never by counting
    # rows -- rendering a throttle as "nothing arrived" would assert something about the
    # lifter's afternoon on the strength of a request nobody answered.
    #
    # `:nothing_to_ask` is unreachable from the box, which only draws the form where there is
    # a window and a connection. It exists because a post is a post: a hand-made one, or one
    # from a page left open across a disconnect, must say nothing rather than report a
    # failure that never happened.
    def check(account_id:, workout:, timing:)
      window = interval(timing)
      return :nothing_to_ask unless window && WithingsConnection.connected?(account_id)
      return :nothing_to_ask if matched(workout[:id])

      fetched?(account_id, window) ? :answered : :unreachable
    end

    # Ask Withings what it has around this session and store it. True where it answered --
    # including where it answered with nothing -- and false where it did not.
    #
    # Reached only from `check`, which is to say only from a press. It used to be reached
    # from `proposal`, which is to say from every view of every record page inside a
    # 24-hour window; see `STILL_ARRIVING` for why that is no longer so.
    #
    # Deliberately does not touch `account_withings.synced_at`. That column is the resume
    # cursor for the measurement poll (#518, #472), and stamping it from a workout fetch
    # would tell that poll it had already read a window of bodyweights it has never seen.
    # Two different fetches wanting one watermark between them is how data goes quietly
    # missing.
    def fetched?(account_id, window)
      token = WithingsConnection.token(account_id)
      return false unless token

      found = Withings.workouts(token, from: window.first.to_date - MARGIN_DAYS,
                                       to: window.last.to_date + MARGIN_DAYS)
      return false unless found

      DB.transaction { found.each { |activity| store(account_id, activity) } }
      true
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
    # `effective_seconds` is no longer among them, and the column it was written to is still
    # in the schema. #586: `effduration` is not a Withings field -- it appears nowhere in the
    # OpenAPI document behind their reference, and 042 added the column for it on the strength
    # of a name in `WORKOUT_FIELDS` that nothing had ever checked. `Withings::WORKOUT_FIELDS`
    # carries the accounting. Taking the key out of here rather than leaving it reading a key
    # that can never arrive is the point: a lookup that is always nil is indistinguishable
    # from a measurement this watch happens not to take, and that ambiguity is the one thing
    # this integration has spent the most effort removing.
    #
    # The column goes in a migration of its own -- #607 -- rather than in this change, because
    # two other branches hold the next migration numbers and a third would land after both or
    # not at all. Until then it is dead at both ends, which is exactly the shape
    # spec/dead_columns_spec.rb was written about. `insert_conflict` updates only the keys this
    # returns, so dropping it here leaves whatever any existing row holds alone rather than
    # nulling it; on every row this app has, that is already null.
    def fields(data)
      data = {} unless data.is_a?(Hash)
      { calories: data['calories'], hr_average: data['hr_average']&.to_i,
        hr_min: data['hr_min']&.to_i, hr_max: data['hr_max']&.to_i }
    end

    # The candidate to offer with the sentence that explains it, or the honest description of
    # having none. No age test in front of it: an overlap is an overlap whether the session
    # was trained this morning or in March, and since nothing here fetches there is no longer
    # a reason to decline to look. See `STILL_ARRIVING`.
    #
    # **A proposal somebody already wrote down wins outright**, ahead of scoring. The backfill
    # records its pick in `proposed_workout_id` and /workouts/withings lists that row, so
    # scoring afresh here could name a different activity for the same session on the two
    # screens -- a lifter answering "yes" in one place about a recording the other place was
    # not offering. There is at most one such row per session, because `WithingsBackfill.offer`
    # refuses to write a second while the first is unanswered, so "the one that was written
    # down" is never ambiguous.
    #
    # And nothing at all for an old session with nothing overlapping. That is not the same
    # silence as "there is nothing to say": it is the refusal to say *"nothing yet"* about a
    # session whose watch upload, if there were one, arrived and was filed months ago.
    def propose(account_id, window, workout_id = nil)
      rows = candidates(account_id, window, workout_id)
      pick = rows.find { |row| row[:proposed_workout_id] } || best(rows, window)
      return offered(pick, window) if pick
      return nil unless still_arriving?(window.last)

      around = nearby(account_id, window, workout_id)
      around.empty? ? { state: :waiting } : elsewhere(around, window)
    end

    # One activity offered for one session, in the shape the page and the review list both
    # read. One spelling of it, because the two paths into it -- scored here, written down by
    # the backfill -- are the pair #560 found disagreeing, and a second literal hash is how
    # they would come to disagree again.
    def offered(row, window)
      { state: :proposed, activity: row, overlap: overlap(row, window),
        span: window.last - window.first, because: because(row, window) }
    end

    # The unanswered activities Withings has around this session without being it.
    #
    # **The rows themselves since #568, and it used to be `.count` of them.** The query was
    # always this query -- it selected the rows and threw them away to keep a number -- and the
    # number turned out to be the whole complaint: *"Withings has 2 activities around this
    # session"* tells a lifter something happened and leaves them unable to check it, or to
    # notice that one of the two is plainly their lift filed against the wrong clock. Handing
    # back what was already selected costs nothing at the database and is the difference
    # between an assertion and evidence. Still one statement, and still no request to Withings.
    #
    # This exists to tell one sentence from another, which is half of #560. `:waiting` said
    # *"nothing from Withings yet -- check back in a minute"* for two situations that are not
    # alike: Withings had nothing for these days, where the watch's upload may genuinely be
    # behind and "yet" is true; and Withings had activities and none of them overlapped this
    # session, where something was recorded, it was simply not this one, and checking back is
    # advice that will never pay off. The reporting account is in the second case and was
    # being told the first.
    #
    # The span is the one a fetch would have stored -- the session's days with `MARGIN_DAYS`
    # either side -- so what comes back answers "what did asking about this session bring
    # back", which is the question the sentence puts.
    #
    # Read over the same unanswered scope as `candidates` rather than over every row, so the
    # sentence stays true in the case that would otherwise quietly falsify it: an activity that
    # *does* overlap but has been claimed by another session or refused already is not
    # something this session may be offered, and listing it would produce "3 activities, none
    # of them overlapping" about a set containing one that does.
    #
    # In time order, because a list of things that happened to somebody's day is read in the
    # order they happened whatever order the cap picks them in.
    def nearby(account_id, window, workout_id = nil)
      from = (window.first.to_date - MARGIN_DAYS).to_time
      to = (window.last.to_date + MARGIN_DAYS + 1).to_time
      unanswered(account_id, workout_id).where { (started_at < to) & (ended_at > from) }
                                        .order(:started_at).all
    end

    # Everything the box needs to say what was recorded instead. #568.
    #
    # The count is the whole set and `nearby` is the part that gets named, so the sentence can
    # say "5 activities" over three lines and a "2 more" without the view doing arithmetic on a
    # truncated list to find out what it is missing. `session` is the interval the overlap was
    # actually tested against, carried here rather than left for the page to fetch again from
    # `@timing`: the box asserts that none of these touches the session, and the two clock
    # times it prints as evidence have to be the two the assertion was made from.
    def elsewhere(rows, window)
      named = rows.min_by(NAMED) { |row| (row[:started_at] - window.first).abs }
      { state: :elsewhere, count: rows.length, session: window,
        nearby: named.sort_by { |row| row[:started_at] } }
    end

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

    # Which day an activity sat on, said against the session rather than against today.
    #
    # Nil where they share a day, because "today" beside a clock time is noise; a phrase only
    # where the day differs, which inside `MARGIN_DAYS` is almost always the one either side.
    #
    # **Relative to the session and never to now**, which is what keeps it true on an old
    # record: "yesterday" printed on a session from March would be a claim about this morning.
    # Both stamps are naive and written by this process in one zone -- the assumption this
    # module's header sets out -- so the difference between them is read in that zone and holds
    # wherever the reader is, which a date printed on its own would not.
    def day_apart(at, window)
      days = (at.to_date - window.first.to_date).to_i
      return nil if days.zero?

      side = days.negative? ? 'before' : 'after'
      days.abs == 1 ? "the day #{side}" : "#{days.abs} days #{side}"
    end

    # Everything that could still be this session: unclaimed, un-refused, and overlapping.
    #
    # **Overlap is the gate.** `withings.start < session.end AND withings.end > session.start`
    # -- strict on both sides, so two activities that merely touch at an instant are not
    # candidates for each other. Everything else about the match is a score over these; a row
    # that does not overlap is not ranked low, it is not a candidate at all.
    #
    # The two local names are `opened`/`closed` rather than the column names, and that is not
    # decoration. Inside a virtual row block a bare `started_at` resolves to the *local
    # variable* where one is in scope and to the column where none is, so naming the locals
    # after the columns would compare each column to itself and match everything.
    #
    # **An activity already offered to a different session is not a candidate for this one.**
    # A backfill can leave a proposal against a session from March, and offering the same
    # activity here as well would be one recording asking two sessions to claim it -- with
    # only one of them able to, since `workout_id` is unique, so the loser's yes would
    # silently do nothing. The session it was offered to is still allowed to see it, which is
    # the ordinary case the moment a backfill and the forward flow overlap on one session.
    def candidates(account_id, window, workout_id = nil)
      opened, closed = window
      unanswered(account_id, workout_id).where { (started_at < closed) & (ended_at > opened) }
                                        .order(:started_at).all
    end

    # Everything this session is still allowed to be offered, before the overlap gate: not
    # claimed, not refused, and not already promised to somebody else's session.
    #
    # One spelling, shared by `candidates` and `nearby`, on the same argument
    # `WithingsProposals.outstanding` makes for its own: the count and the list have to mean
    # the same thing by "still a question", and two copies of a four-part filter drift on
    # exactly the clause nobody is watching. Here that drift would read as "2 activities, none
    # of them this session" printed over a box offering one of them.
    def unanswered(account_id, workout_id = nil)
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil)
                            .where { (proposed_workout_id =~ nil) | (proposed_workout_id =~ workout_id) }
    end

    # The one to propose. Highest score, and the nearest start where two score the same.
    #
    # Nearest-start as the tie-break rather than anything cleverer, because the tie this
    # actually breaks is two recordings of the same training -- a watch and a phone both
    # listening -- and the one that began closest to the first set is the one that was
    # started for it.
    def best(rows, window)
      rows.min_by { |row| [-score(row, window), (row[:started_at] - window.first).abs] }
    end

    # How much of the session the activity covers, plus a nudge for being tagged as lifting.
    #
    # A ratio of the *session's* length rather than of the activity's, or of their union.
    # The question being answered is "is this recording of this session", and a watch left
    # running for an hour after the bar went down should not be penalised for it -- it still
    # covered the session. The reverse case is caught: an activity touching a tenth of the
    # session scores a tenth, whatever else it has going for it.
    def score(row, window)
      (overlap(row, window) / (window.last - window.first).to_f) +
        (LIFTING.include?(row[:category]) ? CATEGORY_BONUS : 0)
    end

    def overlap(row, window)
      ([window.last, row[:ended_at]].min - [window.first, row[:started_at]].max).to_i
    end

    # The score in one sentence, which is what propose-and-confirm actually needs. A number
    # between nought and one and a quarter is not something a lifter can agree or disagree
    # with; "these overlap for 48 of 52 minutes" is, and it is the same fact.
    #
    # **The category is named here only where it scored**, which is why this reads `LIFTING`
    # and not the whole of `CATEGORIES` now that there is a whole of `CATEGORIES` to read.
    # This sentence is the score said in words -- overlap, and the quarter for looking like
    # lifting -- so "and Withings called it bicycling" under an offer would name a label that
    # contributed nothing and read as though it had. The box that names every category is
    # #568's, and there the name is the fact rather than a term of the sum.
    def because(row, window)
      said = called(row[:category]) if LIFTING.include?(row[:category])
      phrase = "overlaps this session for #{Timing.phrase(overlap(row, window))} " \
               "of its #{Timing.phrase((window.last - window.first).to_i)}"
      said ? "#{phrase}, and Withings called it #{said.downcase}" : phrase
    end

    # The lifter saying yes. Scoped to the account, and refused where either side has already
    # been answered -- a second confirmation arriving from a stale page must not move a match
    # that is already made, and the unique index on `workout_id` would make it an exception
    # rather than a no-op if it tried.
    # How many rows it linked -- one, or none where there was nothing left to link. A count
    # rather than a flag because "nothing happened" and "it was refused" are the same answer
    # here and a boolean would invite a caller to treat them as different.
    #
    # **And every other question about this session is withdrawn in the same breath**, which
    # is the first half of #555. A session can carry a proposal from a backfill *and* be
    # matched from its own record page to a second recording of the same afternoon -- a phone
    # listening as well as the watch, an activity split in two in the Withings app -- and
    # until now the backfill's row was left exactly as it was: unclaimed, un-refused, still
    # naming a session that had had its answer for months. It went on being counted as a
    # question on the workouts list and in settings, it went on being listed at
    # /workouts/withings, and the only control offered for it was a Yes that landed here and
    # was refused. A question about a session is answered when the session is answered, by
    # whichever activity, and the column that carries the question has to say so.
    #
    # In one transaction with the link, because the two writes are one answer: a crash between
    # them would leave precisely the state this exists to end.
    def confirm(account_id:, workout_id:, external_id:)
      DB.transaction do
        answered = matched(workout_id)
        linked = answered ? 0 : link(account_id, workout_id, external_id)
        withdraw(account_id, workout_id) if answered || linked.positive?
        linked
      end
    end

    # The link itself, on the terms above: this account's activity, and only one that has not
    # already been claimed or refused.
    def link(account_id, workout_id, external_id)
      DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil, dismissed_at: nil)
                            .update(workout_id:)
    end

    # Every open question about this session, withdrawn, because the session now has an answer.
    #
    # Only the rows that are still questions: the activity that was just claimed or refused
    # excludes itself, since the answer was written first and this filters on the two columns
    # that carry it. That is deliberate rather than incidental -- an activity the lifter
    # confirmed keeps the record that a backfill proposed it, and what goes is the promise
    # nobody can keep.
    #
    # Called on a yes that linked nothing as well as on one that linked a row, which is the
    # stale-page case #555 is about: the session was answered from somewhere else while the
    # queue was on screen, so the tap is not a match to make but a question to close. There is
    # no third possibility to worry about -- a yes naming an activity that no longer exists,
    # against a session with no answer at all, leaves the session's question standing, which
    # is right, because nothing has answered it.
    def withdraw(account_id, workout_id)
      DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id,
                                   workout_id: nil, dismissed_at: nil)
                            .update(proposed_workout_id: nil)
    end

    # The other direction: a proposal about a session that is *still* asking, held by an
    # activity that has since been claimed by another session or refused outright. #555.
    #
    # `proposed_workout_id` is unique, so that dead proposal holds the session's only slot.
    # Nothing could ever fill it -- the activity is answered, so `standing` cannot see it and
    # the backfill believes the session has no proposal at all -- and the next run that picks
    # a second activity for that session sent its `UPDATE` straight into the index. From the
    # rake task that was a stack trace after the year's requests were spent; from the import
    # button (#558) it was a 500 on the settings page of somebody who had just pressed it.
    #
    # Cured here, at the write that wants the slot, rather than at every answer that can
    # strand one. Two reasons, and the second is the stronger. Rows stranded before this
    # shipped exist already and no future answer will ever visit them, so the cure has to live
    # somewhere a later run passes anyway; and a state cured in two places is a state cured
    # two slightly different ways, which is how `standing` and `candidates` came to disagree
    # in #560.
    def reclaim(account_id, workout_id)
      DB[:withings_workouts].where(account_id:, proposed_workout_id: workout_id)
                            .exclude(workout_id: nil, dismissed_at: nil)
                            .update(proposed_workout_id: nil)
    end

    # The lifter saying no, which #520 requires to stick per workout and permanently.
    #
    # Two writes, because "no" means two things at once and only one of them has an activity
    # to hang on. The session is marked asked-and-answered, which is what silences the prompt
    # even for a session Withings will never have anything for. And the activity that was on
    # screen, where there was one, is set aside too: it was offered *because* it overlaps this
    # session, so a lifter saying it is not this session is saying it is not a lift they
    # logged -- and offering it to the session half an hour either side would be the same nag
    # wearing a different session's clothes.
    #
    # The row survives both. Withings will send it again on the next fetch, and a delete
    # would simply let it come back and be proposed afresh.
    #
    # Three writes since #555, and the third is the same one `confirm` makes: a no is an
    # answer about the session, so every open question about it is withdrawn too. Ordinarily
    # that is the row on the next line and the two writes agree; where they do not -- a
    # backfill proposed one activity and the page the lifter pressed No on was offering
    # another -- the difference is exactly a question left standing about a session that has
    # said it does not want to be asked.
    def dismiss(account_id:, workout_id:, external_id: nil)
      now = Time.now
      DB.transaction do
        DB[:workouts].where(id: workout_id, account_id:).update(withings_dismissed_at: now)
        withdraw(account_id, workout_id)
        next if external_id.to_s.empty?

        DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil)
                              .update(dismissed_at: now)
      end
    end
  end
end

