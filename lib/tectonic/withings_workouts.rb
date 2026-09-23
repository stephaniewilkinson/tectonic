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
    # What Withings' integer means. 16 is "Lift weights" and 17 is "Fitness", which are the
    # two a barbell session plausibly gets tagged as.
    #
    # **Scoring only.** Nothing filters on this. A lifter who tapped "Other", or whose watch
    # guessed, still lifted, and a category test that excluded them would turn a confident
    # guess into a missing feature.
    LIFTING = { 16 => 'Lift weights', 17 => 'Fitness' }.freeze
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
    # How long after a session ends this keeps asking Withings about it.
    #
    # #520 requires that the page look again each time it is opened, because the watch's
    # upload is seconds to minutes behind -- so it cannot be a one-shot. It does not follow
    # that it should be forever. A session that ended yesterday with nothing overlapping it
    # has nothing coming, and re-asking on every view of a year of training turns browsing
    # history into a few hundred API calls -- which is how a read-only integration gets
    # itself rate-limited, and a throttled fetch is the one failure this page cannot render
    # honestly (see `Withings.workouts`).
    #
    # A day rather than an hour because a lifter who taps finish and reads the record the
    # next morning is ordinary, and the proposal should still be there. Past it the page
    # goes quiet rather than saying anything: an old session with no match has nothing to
    # say, and #520's whole complaint about "no activity found" is that it is a claim.
    #
    # It is also the seam a backfill would widen. #520 declines one outright -- "matching an
    # arbitrary past session is the hard version of this problem and this flow avoids it
    # entirely" -- so this is the forward flow and only the forward flow.
    LOOKS_BACK = 24 * 60 * 60

    module_function

    # What the record page should say about Withings, or nil where it should say nothing.
    #
    # Four answers, and they are four rather than two because the differences between them
    # are the substance of #520:
    #
    #   :matched  -- the lifter said yes; the watch's numbers are the session's numbers
    #   :proposed -- something overlaps, with a sentence saying how much
    #   :waiting  -- Withings answered and had nothing *yet*, which is not the same as never
    #   :unreachable -- Withings did not answer, which is not the same as nothing
    #
    # The last two are one state in any implementation that folds them, and folding them is
    # the trap: `Withings.answered` turns a rate-limit (status 601, delivered as HTTP 200
    # like every other Withings error) into the same nil as a revoked token, so a throttled
    # fetch and an empty one are indistinguishable by the time the answer gets here. They
    # are told apart by nil against `[]` and never by counting rows, because a page that
    # renders a throttle as "no activity" is lying about a thing that exists.
    def proposal(account_id:, workout:, timing:)
      found = matched(workout[:id])
      return { state: :matched, activity: found } if found
      return nil if workout[:withings_dismissed_at] || !WithingsConnection.connected?(account_id)

      window = interval(timing)
      return nil unless window && recent?(window.last)
      return { state: :unreachable } unless fetched?(account_id, window)

      propose(account_id, window)
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

    def recent?(ended_at) = Time.now - ended_at < LOOKS_BACK

    # Ask Withings what it has around this session and store it. True where it answered --
    # including where it answered with nothing -- and false where it did not.
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
        category: activity['category']&.to_i, attrib: activity['attrib']&.to_i,
        modified_at: stamp(activity['modified']), **fields(activity['data']) }
    end

    def stamp(epoch) = epoch.nil? ? nil : Time.at(epoch.to_i)

    # The measurements, which arrive under `data` and only because they were asked for by
    # name. Nil rather than zero where one is absent: a watch that recorded no heart rate and
    # a watch that recorded a resting one are different, and a zero would read as the second.
    def fields(data)
      data = {} unless data.is_a?(Hash)
      { calories: data['calories'], effective_seconds: data['effduration']&.to_i,
        hr_average: data['hr_average']&.to_i, hr_min: data['hr_min']&.to_i,
        hr_max: data['hr_max']&.to_i }
    end

    # The best candidate with the sentence that explains it, or the waiting state.
    def propose(account_id, window)
      pick = best(candidates(account_id, window), window)
      return { state: :waiting } unless pick

      { state: :proposed, activity: pick, overlap: overlap(pick, window),
        span: window.last - window.first, because: because(pick, window) }
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
    def candidates(account_id, window)
      opened, closed = window
      DB[:withings_workouts].where(account_id:, workout_id: nil, dismissed_at: nil)
                            .where { (started_at < closed) & (ended_at > opened) }
                            .order(:started_at).all
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
        (LIFTING.key?(row[:category]) ? CATEGORY_BONUS : 0)
    end

    def overlap(row, window)
      ([window.last, row[:ended_at]].min - [window.first, row[:started_at]].max).to_i
    end

    # The score in one sentence, which is what propose-and-confirm actually needs. A number
    # between nought and one and a quarter is not something a lifter can agree or disagree
    # with; "these overlap for 48 of 52 minutes" is, and it is the same fact.
    def because(row, window)
      said = LIFTING[row[:category]]
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
    def confirm(account_id:, workout_id:, external_id:)
      return 0 if matched(workout_id)

      DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil, dismissed_at: nil)
                            .update(workout_id:)
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
    def dismiss(account_id:, workout_id:, external_id: nil)
      now = Time.now
      DB.transaction do
        DB[:workouts].where(id: workout_id, account_id:).update(withings_dismissed_at: now)
        next if external_id.to_s.empty?

        DB[:withings_workouts].where(account_id:, external_id:, workout_id: nil)
                              .update(dismissed_at: now)
      end
    end
  end
end

